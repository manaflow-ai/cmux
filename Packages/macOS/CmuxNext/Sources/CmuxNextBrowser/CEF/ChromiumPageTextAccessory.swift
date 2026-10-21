import AppKit
import ObjectiveC

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
    static let selector = NSSelectorFromString("preferredTextAccessoryPlacement")

    private typealias Getter = @convention(c) (AnyObject, Selector) -> Int

    /// Gives `viewClass` a `preferredTextAccessoryPlacement` that answers
    /// `.invisible` where `hides(view)` is true and the class's earlier answer
    /// elsewhere. Safe to call again.
    static func install(on viewClass: AnyClass, hides: @escaping @MainActor (NSView) -> Bool) {
        let existing = class_getInstanceMethod(viewClass, selector)
        let earlier: Getter? = existing.map { unsafeBitCast(method_getImplementation($0), to: Getter.self) }
        let sel = Self.selector
        let answer: @convention(block) (NSView) -> Int = { view in
            // AppKit asks on the main thread; anywhere else keeps the earlier answer.
            if Thread.isMainThread, MainActor.assumeIsolated({ hides(view) }) { // main-proof: guarded by Thread.isMainThread
                return NSTextCursorAccessoryPlacement.invisible.rawValue
            }
            return earlier?(view, sel) ?? NSTextCursorAccessoryPlacement.unspecified.rawValue
        }
        let imp = imp_implementationWithBlock(answer)
        if let existing, let types = method_getTypeEncoding(existing) {
            _ = class_replaceMethod(viewClass, sel, imp, types)
        } else {
            _ = class_replaceMethod(viewClass, sel, imp, "q@:")
        }
    }

    /// Installs the answer on Chromium's `RenderWidgetHostViewCocoa` once CEF's
    /// classes exist; `hides` says whether a view shows a cmux page.
    @discardableResult
    static func install(hides: @escaping @MainActor (NSView) -> Bool) -> Bool {
        guard let viewClass = NSClassFromString("RenderWidgetHostViewCocoa") else { return false }
        install(on: viewClass, hides: hides)
        return true
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
