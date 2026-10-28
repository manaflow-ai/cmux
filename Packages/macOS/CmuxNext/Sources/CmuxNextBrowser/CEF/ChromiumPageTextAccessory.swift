import AppKit
import CmuxNextCompat
import ObjectiveC
import os

/// Hides macOS's caret accessory in Chromium's view of a cmux page.
///
/// Since macOS 14 the system draws a small glass bubble beside the caret of the
/// focused text field: the input source, Caps Lock or dictation. In the shared
/// composer the caret of an empty prompt sits just above the + (attach) button,
/// and the bubble covered it (Leo, 2026-10-21). AppKit asks the focused text
/// input client for `preferredTextAccessoryPlacement` (`NSTextInputClient`,
/// macOS 14) and draws no bubble for `.invisible`. The WebKit views of cmux
/// pages answer that themselves (`PageWKWebView`, the agent pane's web view).
/// Chromium's text input client is its `RenderWidgetHostViewCocoa`, which cmux
/// cannot subclass, so this adds the answer to that class: `.invisible` for a
/// view whose window shows a cmux page, and the class's earlier answer (the
/// system's placement when it had none) for a web page in a browser tab.
nonisolated enum ChromiumPageTextAccessory {
    /// `-[NSTextInputClient preferredTextAccessoryPlacement]`.
    static let selector = #selector(NSTextInputClient.preferredTextAccessoryPlacement)

    private typealias Getter = @convention(c) (AnyObject, Selector) -> Int

    /// The answer of a text input client cmux implements itself (host mode's
    /// ``ChromiumHostPageView``): `.invisible` on a cmux
    /// page, the system's placement on a web page, the rule ``install(hides:)``
    /// gives Chromium's own view.
    static func placement(showsCmuxPage: Bool) -> NSTextCursorAccessoryPlacement {
        showsCmuxPage ? .invisible : .unspecified
    }

    /// The classes that already carry the answer: a second install is a no-op.
    private static let installed = Mutex<Set<ObjectIdentifier>>([])

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef")

    /// Gives `viewClass` a `preferredTextAccessoryPlacement` that answers
    /// `.invisible` where `hides(view)` is true and the class's earlier answer
    /// elsewhere. Installing on the same class again changes nothing (the first
    /// `hides` stays); returns whether this call installed it.
    @discardableResult
    static func install(on viewClass: AnyClass, hides: @escaping @MainActor (NSView) -> Bool) -> Bool {
        let id = ObjectIdentifier(viewClass)
        guard installed.withLock({ $0.insert(id).inserted }) else { return false }
        // SAFETY: the Method of a live class (classes are never unloaded); nil when it has none.
        let existing = unsafe class_getInstanceMethod(viewClass, selector)
        // SAFETY: the method is `-(NSTextCursorAccessoryPlacement)preferredTextAccessoryPlacement`, whose IMP has
        // the C type `Getter` (self, _cmd) -> NSInteger.
        let earlier: Getter? = unsafe existing.map { unsafe unsafeBitCast(method_getImplementation($0), to: Getter.self) }
        let sel = Self.selector
        let answer: @convention(block) (NSView) -> Int = { view in
            // AppKit asks on the main thread; anywhere else keeps the earlier answer.
            if Thread.isMainThread, MainActor.assumeIsolated({ hides(view) }) { // main-proof: guarded by Thread.isMainThread
                return NSTextCursorAccessoryPlacement.invisible.rawValue
            }
            return earlier?(view, sel) ?? NSTextCursorAccessoryPlacement.unspecified.rawValue
        }
        let imp = imp_implementationWithBlock(answer)
        // SAFETY: `imp` is a block IMP of the getter's type (NSView) -> NSInteger; the type encoding is the
        // existing method's (a static runtime string) or "q@:", the same signature.
        if let existing = unsafe existing, let types = unsafe method_getTypeEncoding(existing) {
            _ = unsafe class_replaceMethod(viewClass, sel, imp, types)
        } else {
            _ = unsafe class_replaceMethod(viewClass, sel, imp, "q@:")
        }
        return true
    }

    /// Installs the answer on Chromium's `RenderWidgetHostViewCocoa` once CEF's
    /// classes exist; `hides` says whether a view shows a cmux page. Logs when
    /// the class is missing (a renamed class would bring the bubble back).
    @discardableResult
    static func install(hides: @escaping @MainActor (NSView) -> Bool) -> Bool {
        guard let viewClass = NSClassFromString("RenderWidgetHostViewCocoa") else {
            logger.error("caret accessory: RenderWidgetHostViewCocoa missing; cmux pages in Chromium keep the system caret bubble")
            return false
        }
        return install(on: viewClass, hides: hides)
    }
}

extension CEFRuntime {
    /// Whether `window` is the Chromium page window of a cmux page (a tab with a
    /// ``CEFTab/pageThemeSurface``, which only the app's page host sets).
    func showsCmuxPage(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return hosts.values.contains { host in
            guard let tab = host.visibleTab, tab.pageThemeSurface != nil else { return false }
            return tab.isPageWindow(window)
        }
    }
}
