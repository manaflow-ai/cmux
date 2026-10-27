import AppKit
import ObjectiveC

/// Keeps Chromium's page windows (`CefNSWindow`: a page, docked or undocked
/// DevTools) from becoming the main window. Each one sits inside a cmux
/// window as a child window and takes key so the page gets the keyboard
/// (IME too). AppKit makes a key window main as well when it can be main,
/// and the cmux window then draws inactive while the user works in its own
/// page: grey traffic lights, grey Liquid Glass, dimmed tabs and sidebar
/// selection. The cmux window has to stay main, as it does for its panels
/// (palette, notifications, group editor). Chromium's own dialogs and
/// bubbles say no to main the same way, so key without main is a path
/// Chromium already runs. The page window still becomes key; nothing else
/// changes. `NSApp.mainWindow` also stays the cmux window, which the
/// sheet and dialog fallbacks expect.
///
/// In process only (``BrowserBackend/inProcess``): the runtime installs it after an in-process
/// boot. With the Chromium Host the page is a view of the cmux window (`ChromiumHostPageView`), so
/// no page window can take main, and `CefNSWindow` is not even a class of this process.
nonisolated enum ChromiumPageWindowMain {
    /// Overrides `canBecomeMainWindow` on `pageClass` (and its subclasses)
    /// to answer no. Safe to call again.
    @discardableResult
    static func keepOutOfMain(_ pageClass: AnyClass) -> Bool {
        let selector = #selector(getter: NSWindow.canBecomeMain)
        // SAFETY: NSWindow's own Method for the getter (classes are never unloaded).
        guard let inherited = unsafe class_getInstanceMethod(NSWindow.self, selector) else { return false }
        let never: @convention(block) (NSWindow) -> Bool = { _ in false }
        // SAFETY: the block IMP has the getter's type (NSWindow) -> BOOL, and the type encoding is the inherited one.
        unsafe class_replaceMethod(pageClass, selector, imp_implementationWithBlock(never), method_getTypeEncoding(inherited))
        return true
    }

    /// Installs the override on `CefNSWindow` once CEF's classes exist.
    @discardableResult
    static func install() -> Bool {
        guard let pageClass = pageClass() else { return false }
        return keepOutOfMain(pageClass)
    }

    /// `CefNSWindow`, Chromium's page window class; nil until CEF's framework has registered it.
    static func pageClass() -> AnyClass? {
        NSClassFromString("CefNSWindow")
    }
}
