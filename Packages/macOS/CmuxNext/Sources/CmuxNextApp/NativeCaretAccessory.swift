import AppKit
import CmuxNextCompat
import ObjectiveC

/// No macOS caret bubble over cmux's own native text.
///
/// Since macOS 14 the system draws a small glass bubble beside the caret of the
/// focused field: the input source, Caps Lock or dictation. Over cmux's compact
/// fields it covers the controls next to them: the rename field at the top of a
/// sidebar row's context menu put it over the first color dot (Leo, 2026-10-21),
/// as the composer's caret put it over the + button (the web pages answer for
/// themselves: `PageWKWebView`, `ChromiumPageTextAccessory`).
///
/// AppKit asks the focused text input client for `preferredTextAccessoryPlacement`
/// (`NSTextInputClient`, macOS 14) and draws no bubble for `.invisible`. Every
/// native field edits through an `NSTextView`: an `NSTextField` (rename fields,
/// search fields, fields inside menus, SwiftUI's `TextField`) through its window's
/// field editor, a text view as itself. So the answer goes on `NSTextView` once at
/// launch, and every cmux text view and field editor inherits it; a new field needs
/// nothing (`NativeCaretAccessoryTests` checks that no cmux text view answers
/// otherwise). A view from a framework bundled in the app (Sparkle, Sentry,
/// Chromium) keeps the system's answer.
nonisolated enum NativeCaretAccessory {
    /// `-[NSTextInputClient preferredTextAccessoryPlacement]`.
    static let selector = #selector(NSTextInputClient.preferredTextAccessoryPlacement)

    private typealias Getter = @convention(c) (AnyObject, Selector) -> Int

    private static let installed = Mutex(false)
    /// Whether a class comes from a bundled framework, per class (`Bundle(for:)` walks the images).
    private static let thirdPartyClasses = Mutex<[ObjectIdentifier: Bool]>([:])

    /// Gives `NSTextView` its answer; a second call changes nothing. Returns whether this call
    /// installed it.
    @discardableResult
    static func install() -> Bool {
        guard installed.withLock({ done in
            defer { done = true }
            return !done
        }) else { return false }
        // SAFETY: `preferredTextAccessoryPlacement` returns an NSInteger and takes no argument, so its IMP is
        // (self, _cmd) -> Int, the Getter signature; the cast changes no argument or return layout.
        let existing = unsafe class_getInstanceMethod(NSTextView.self, selector)
        let earlier: Getter? = unsafe existing.map { unsafe unsafeBitCast(method_getImplementation($0), to: Getter.self) }
        let sel = selector
        let answer: @convention(block) (NSTextView) -> Int = { view in
            // AppKit asks on the main thread; anywhere else keeps the earlier answer.
            if Thread.isMainThread, let placement = MainActor.assumeIsolated({ Self.placement(for: view) }) { // main-proof: guarded by Thread.isMainThread
                return placement.rawValue
            }
            return earlier?(view, sel) ?? NSTextCursorAccessoryPlacement.unspecified.rawValue
        }
        // SAFETY: `answer` takes (self) and returns Int, the block form of the Getter IMP; the type encoding
        // is the existing method's (a C string the runtime owns for the class's life) or "q@:", NSInteger
        // from (id, SEL), which matches it. The runtime copies the block and the encoding.
        let imp = unsafe imp_implementationWithBlock(answer)
        if let existing, let types = unsafe method_getTypeEncoding(existing) {
            _ = unsafe class_replaceMethod(NSTextView.self, sel, imp, types)
        } else {
            _ = unsafe class_replaceMethod(NSTextView.self, sel, imp, "q@:")
        }
        return true
    }

    /// The placement for `view`: `.invisible` for cmux's own text, nil (the system's answer) for a
    /// view from a bundled framework. A field editor counts as the field it edits.
    @MainActor
    static func placement(for view: NSTextView, isThirdParty: (AnyClass) -> Bool = Self.isThirdParty) -> NSTextCursorAccessoryPlacement? {
        let owner: AnyObject = view.isFieldEditor ? (view.delegate as AnyObject?) ?? view : view
        return isThirdParty(type(of: owner)) ? nil : .invisible
    }

    /// Whether `cls` comes from a framework inside the app bundle (`Contents/Frameworks`).
    static func isThirdParty(_ cls: AnyClass) -> Bool {
        let id = ObjectIdentifier(cls)
        if let known = thirdPartyClasses.withLock({ $0[id] }) { return known }
        let frameworks = Bundle.main.privateFrameworksURL?.standardizedFileURL.path
        let answer = frameworks.map { Bundle(for: cls).bundleURL.standardizedFileURL.path.hasPrefix($0 + "/") } ?? false
        thirdPartyClasses.withLock { $0[id] = answer }
        return answer
    }
}
