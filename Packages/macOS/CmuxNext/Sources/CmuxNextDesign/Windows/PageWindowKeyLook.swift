import AppKit
import ObjectiveC

/// A window keeps AppKit's key look while its own Chromium page window has the keyboard (Lawrence, 2026-11-24: "when
/// changing tab, chief suddenly lights up?").
///
/// A Chromium page (`CefNSWindow`: a browser tab, the agent chat, a page in a split) is a child window of the cmux
/// window that takes key so the page gets the keyboard; the cmux window stays main (`ChromiumPageWindowMain`, #22998)
/// and its backdrop and wash keep the active look (``WindowKeyFamily``, ``ActiveLookScope``). AppKit's controls do not
/// follow main: a Liquid Glass button or pill reads the window's key appearance (`hasKeyAppearance`,
/// `_hasKeyAppearance`, `_hasActiveControls`; measured on macOS 26.5, austins-mac-mini, 2026-11-27), which is false
/// while a child window is key. So every glass control of the window (the Chief header's sidebar and compose circles
/// and its name pill, the toolbar's) drew the inactive grey while the person worked in a page, and each tab switch
/// lit them up for the frames the cmux window held the keys between the two pages (the new page's first-frame hold,
/// about 90 ms) before the new page took them and they greyed again: the flash in Lawrence's video.
///
/// ``NSWindow/keepKeyLookUnderItsPages()`` makes a window answer those getters true while its own page window holds
/// the keys of the active app, so the controls keep one look across a page-to-page switch. AppKit tells a window's
/// views when that window gains or loses key, not when its pages take or give up the keys while it is not key; the
/// window's one key tracker tells them then (``WindowKeyFamily``, ``WindowKeyEnvironment/refresh``). A panel, sheet,
/// another window or another app taking the keys makes the controls inactive as before.
@MainActor
enum PageWindowKeyLook {
    /// The AppKit getters a window's controls read for their key look, all answered the same way.
    static let getters = ["hasKeyAppearance", "_hasKeyAppearance", "_hasActiveControls"]
    /// A method a covered class answers: it marks the class (and its subclasses) as covered.
    static let marker = NSSelectorFromString("cmux_keepsKeyLookUnderItsPages") // crash-allow: a method this file adds, only checked for

    /// Whether `key` is a page window of `window`'s own: a `CefNSWindow` child of it, or a page that page opened over
    /// itself (DevTools). A page window with no parent yet acts for the main window, as `KeyWindowRole` resolves it.
    /// A panel, sheet or other window is not.
    static func holds(_ key: NSWindow, for window: NSWindow) -> Bool {
        guard key !== window else { return false }
        var current = key
        // Window chains are a few levels deep; the bound guards a cycle.
        for _ in 0..<32 {
            guard isChromiumPageWindow(current), current.sheetParent == nil else { return false }
            guard let parent = current.parent else { return current === key && window.isMainWindow }
            if !isChromiumPageWindow(parent) { return parent === window }
            current = parent
        }
        return false
    }

    /// Makes `windowClass` answer AppKit's key-look getters true while a window's tracker says one of its pages holds
    /// the keys (``WindowKeyFamily/keepsKeyLookNow()``). AppKit's own classes (`NSWindow`, `NSPanel`) are left alone,
    /// and a class it already covers (or a subclass of one) is not wrapped again.
    ///
    /// - Parameter windowClass: A window class of the app (the main window's, a popup's).
    /// - Returns: Whether the class answers the getters this way now.
    @discardableResult
    static func install(on windowClass: NSWindow.Type) -> Bool {
        let windowClass = declared(windowClass)
        if class_getInstanceMethod(windowClass, marker) != nil { return true }
        guard windowClass != NSWindow.self, windowClass != NSPanel.self else { return false }
        for name in getters {
            let selector = NSSelectorFromString(name) // crash-allow: AppKit private getters, overridden only when NSWindow has them
            guard let method = class_getInstanceMethod(windowClass, selector) else { continue }
            let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
            let answer: @convention(block) (NSWindow) -> Bool = { window in
                let appKit = original(window, selector)
                // AppKit reads these from render threads too: off the main thread it keeps AppKit's answer.
                guard !appKit, pthread_main_np() != 0 else { return appKit }
                return MainActor.assumeIsolated { WindowKeyFamily.existing(of: window)?.keepsKeyLookNow() ?? false } // main-proof: pthread_main_np() checked on the line above
            }
            class_replaceMethod(windowClass, selector, imp_implementationWithBlock(answer), method_getTypeEncoding(method))
        }
        let mark: @convention(block) (NSWindow) -> Void = { _ in }
        class_addMethod(windowClass, marker, imp_implementationWithBlock(mark), "v@:")
        return true
    }

    typealias Getter = @convention(c) (NSWindow, Selector) -> Bool

    /// The class an app declared: past the subclass Key-Value Observing makes for an observed window
    /// (`NSKVONotifying_...`), which Swift's `type(of:)` returns.
    private static func declared(_ windowClass: NSWindow.Type) -> NSWindow.Type {
        var current: AnyClass = windowClass
        while NSStringFromClass(current).hasPrefix("NSKVONotifying_"), let superclass = class_getSuperclass(current) { current = superclass }
        return (current as? NSWindow.Type) ?? windowClass
    }

    /// `CefNSWindow`: a Chromium page window.
    static func isChromiumPageWindow(_ window: NSWindow) -> Bool {
        guard let pageClass = NSClassFromString("CefNSWindow") else { return false }
        return window.isKind(of: pageClass)
    }
}

extension NSWindow {
    /// Keeps this window's AppKit key look (its glass controls') while its own Chromium page window holds the keys
    /// (``PageWindowKeyLook``). The window kit calls it for every window it installs.
    func keepKeyLookUnderItsPages() {
        guard PageWindowKeyLook.install(on: type(of: self)) else { return }
        WindowKeyFamily.of(self).keepsPageKeyLook = true
    }
}
