import AppKit
import ObjectiveC

/// Keeps Chromium's occlusion checker off cmux's embedded page windows.
///
/// `WebContentsOcclusionCheckerMac` takes every window with no parent window
/// that holds a web contents view (`-[NSWindow containsWebContentsViewCocoa]`)
/// for a browser window. When such a window is ordered, moved or resized, it
/// schedules a check for the next run-loop pass that calls
/// `-[NSApp orderedWindows]`: a synchronous WindowServer query that waits
/// until the WindowServer has applied cmux's pending Core Animation
/// transaction. The CEF fork's tracker orders a hidden or detached page window
/// out after it removes it from its parent window (`-hideNow`,
/// `-setDetached:YES`), so every page that hid or detached cost a check: 8-45 ms
/// on the main thread in each Cmd-N with 60 workspaces (cmux22, macOS 27).
///
/// An embedded page window (`CefNSWindow -isEmbeddedInParentView`) now answers
/// no: its parent view decides whether the page shows, a child window is not
/// in the checker's window list anyway, and the fork already keeps a headless
/// page window from being occluded. A page window that is not embedded keeps
/// Chromium's answer. The CEF fork carries the same override
/// (manaflow-ai/cef `cmux/8103-cmux45-occlusion-window-list`); delete this one
/// when the pinned CEF has it.
nonisolated enum ChromiumPageWindowOcclusion {
    /// Chromium's `NSWindow` category method that the checker asks.
    // crash-allow: only looked up with class_getInstanceMethod, which returns nil (no install) when it is missing.
    static let selector = NSSelectorFromString("containsWebContentsViewCocoa")
    /// The fork's `CefNSWindow` getter for an embedded page window.
    // crash-allow: only looked up with class_getInstanceMethod, which returns nil (no install) when it is missing.
    static let embeddedSelector = NSSelectorFromString("isEmbeddedInParentView")

    private typealias Query = @convention(c) (AnyObject, Selector) -> Bool

    /// Overrides `containsWebContentsViewCocoa` on `pageClass` to answer no
    /// while the window is embedded and to ask the superclass otherwise.
    /// Returns false (and changes nothing) when Chromium's method or the
    /// fork's getter is missing. Safe to call again.
    @discardableResult
    static func keepOutOfOcclusionChecks(_ pageClass: AnyClass) -> Bool {
        let sel = selector
        let embeddedSel = embeddedSelector
        guard let superclass = class_getSuperclass(pageClass),
              let inherited = class_getInstanceMethod(superclass, sel),
              let embeddedMethod = class_getInstanceMethod(pageClass, embeddedSel)
        else { return false }
        // The superclass's method, not the class's own: a second install
        // must not call itself.
        let chromium = unsafeBitCast(method_getImplementation(inherited), to: Query.self)
        let isEmbedded = unsafeBitCast(method_getImplementation(embeddedMethod), to: Query.self)
        let answer: @convention(block) (NSWindow) -> Bool = { window in
            isEmbedded(window, embeddedSel) ? false : chromium(window, sel)
        }
        class_replaceMethod(pageClass, sel, imp_implementationWithBlock(answer), method_getTypeEncoding(inherited))
        return true
    }
}
