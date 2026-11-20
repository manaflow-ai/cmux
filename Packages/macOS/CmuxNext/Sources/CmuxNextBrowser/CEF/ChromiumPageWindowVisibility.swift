import AppKit
import ObjectiveC

/// An embedded page window is on screen exactly when its parent window is
/// (https://github.com/manaflow-ai/cmux/issues/45785).
///
/// A hosted page (``CEFLayerHosting``) draws in the cmux window's own layers.
/// Its `CefNSWindow` is only the page's input window, a child of the cmux
/// window that draws nothing. Chromium still reads that window's own
/// `-isOnActiveSpace` and `-occlusionState` on each of its occlusion flips
/// (`NativeWidgetNSWindowBridge::OnSpaceActivationMayHaveChanged`). A
/// hidden answer there sets the page's compositor invisible: it stops drawing,
/// Viz releases its backbuffers, and the page goes hidden
/// (`document.visibilityState`). The hosted layer then shows nothing until the
/// renderer draws a new frame, which a renderer busy loading a chat or
/// streaming an agent's turn takes hundreds of ms to do. The chat's content
/// vanished and the window's glass showed through.
///
/// The child windows flip on their own while the cmux window stays visible
/// (another app's window over the panes but not over the whole window, an app
/// switch): in a NIGHTLY's flicker ring, 516 of 528 sub-second hides of a chat
/// page came with an occlusion flip of the cmux window's child windows (page
/// and divider panels) and none of the cmux window itself.
///
/// So an embedded page window answers both from its parent window, and a
/// parent's own flip is passed on to its embedded page windows, so Chromium
/// still hides a page whose cmux window is minimized, hidden or on another
/// Space. A covered cmux window is still on the active Space, so its pages
/// stay drawn, as Chromium's own windows' pages do. A page window that is not embedded, or not a child window yet
/// (a detached page, a page before it shows), keeps Chromium's answer.
nonisolated enum ChromiumPageWindowVisibility {
    static let occlusionSelector = #selector(getter: NSWindow.occlusionState)
    static let activeSpaceSelector = #selector(getter: NSWindow.isOnActiveSpace)

    static let parentSelector = #selector(getter: NSWindow.parent)

    private typealias StateQuery = @convention(c) (AnyObject, Selector) -> UInt
    private typealias Query = @convention(c) (AnyObject, Selector) -> Bool
    private typealias ObjectQuery = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?

    /// `object`'s own implementation of `sel`, called as `type`. AppKit's getters are read through their
    /// implementations, as Chromium reads them: the swizzled getters run from AppKit and Chromium, not from Swift.
    private static func implementation<T>(of sel: Selector, in object: AnyObject, as type: T.Type) -> T? {
        // The method itself, not class_getMethodImplementation, which answers the forwarding stub for a missing one.
        class_getInstanceMethod(object_getClass(object), sel).map { unsafeBitCast(method_getImplementation($0), to: type) }
    }

    /// Overrides `occlusionState` and `isOnActiveSpace` on `pageClass` to
    /// answer the parent window's state while the window is an embedded child
    /// window, and the superclass's otherwise. Returns false (and changes
    /// nothing) when the fork's embedded getter is missing. Safe to call again.
    @discardableResult
    static func followParentWindow(_ pageClass: AnyClass) -> Bool {
        let occlusionSel = occlusionSelector
        let spaceSel = activeSpaceSelector
        let parentSel = parentSelector
        let embeddedSel = ChromiumPageWindowOcclusion.embeddedSelector
        guard let superclass = class_getSuperclass(pageClass),
              let inheritedOcclusion = class_getInstanceMethod(superclass, occlusionSel),
              let inheritedSpace = class_getInstanceMethod(superclass, spaceSel),
              let embeddedMethod = class_getInstanceMethod(pageClass, embeddedSel)
        else { return false }
        // The superclass's methods, not the class's own: a second install must not call itself.
        let ownOcclusion = unsafeBitCast(method_getImplementation(inheritedOcclusion), to: StateQuery.self)
        let ownSpace = unsafeBitCast(method_getImplementation(inheritedSpace), to: Query.self)
        let isEmbedded = unsafeBitCast(method_getImplementation(embeddedMethod), to: Query.self)
        let embeddingParent: (AnyObject) -> AnyObject? = { window in
            guard isEmbedded(window, embeddedSel) else { return nil }
            return implementation(of: parentSel, in: window, as: ObjectQuery.self)?(window, parentSel)?.takeUnretainedValue()
        }
        let occlusion: @convention(block) (AnyObject) -> UInt = { window in
            guard let parent = embeddingParent(window),
                  let state = implementation(of: occlusionSel, in: parent, as: StateQuery.self) else { return ownOcclusion(window, occlusionSel) }
            return state(parent, occlusionSel)
        }
        let space: @convention(block) (AnyObject) -> Bool = { window in
            guard let parent = embeddingParent(window),
                  let onSpace = implementation(of: spaceSel, in: parent, as: Query.self) else { return ownSpace(window, spaceSel) }
            return onSpace(parent, spaceSel)
        }
        class_replaceMethod(pageClass, occlusionSel, imp_implementationWithBlock(occlusion),
                            method_getTypeEncoding(inheritedOcclusion))
        class_replaceMethod(pageClass, spaceSel, imp_implementationWithBlock(space), method_getTypeEncoding(inheritedSpace))
        return true
    }

    /// Whether `window` is an embedded page window (its class answers the fork's getter, and it says yes).
    static func isEmbeddedPage(_ window: NSWindow) -> Bool {
        let sel = ChromiumPageWindowOcclusion.embeddedSelector
        guard let method = class_getInstanceMethod(object_getClass(window), sel) else { return false }
        return unsafeBitCast(method_getImplementation(method), to: Query.self)(window, sel)
    }

    /// Posts an occlusion change for each embedded page window of `parent`, whose own occlusion changed: the page
    /// windows answer from it (``followParentWindow(_:)``), and Chromium reads a window's state only on that
    /// window's own notification. Nothing for a page window's own flip.
    /// ``ChromiumWindowGuard``, which watches every window's occlusion, reports each flip here.
    @MainActor static func parentOcclusionChanged(_ parent: NSWindow, post: ((NSWindow) -> Void)? = nil) {
        guard !isEmbeddedPage(parent) else { return }
        for child in parent.childWindows ?? [] where isEmbeddedPage(child) {
            if let post { post(child) } else { postOcclusionChange(of: child) }
        }
    }

    /// AppKit's own notice of `window`'s occlusion change, which Chromium's window delegate observes.
    @MainActor static func postOcclusionChange(of window: NSWindow) {
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }
}
