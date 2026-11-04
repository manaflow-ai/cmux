public import AppKit
public import WebKit

extension String {
    /// Whether this Objective-C or Swift class name belongs to WebKit's Web Inspector.
    public var cmuxNamesWebInspectorClass: Bool {
        contains("WKInspector") || contains("WebInspector")
    }
}

extension NSObject {
    /// Whether this object's class belongs to WebKit's Web Inspector.
    public var cmuxBelongsToWebInspector: Bool {
        String(describing: type(of: self)).cmuxNamesWebInspectorClass ||
            NSStringFromClass(type(of: self)).cmuxNamesWebInspectorClass
    }
}

extension NSResponder {
    /// Whether this responder is, or sits inside, a Web Inspector view
    /// hierarchy. Walks at most 64 superviews.
    public var cmuxIsInsideWebInspector: Bool {
        if cmuxBelongsToWebInspector {
            return true
        }
        guard let view = self as? NSView else { return false }
        var node: NSView? = view
        var hops = 0
        while let current = node, hops < 64 {
            if current.cmuxBelongsToWebInspector {
                return true
            }
            node = current.superview
            hops += 1
        }
        return false
    }
}

extension WKWebView {
    /// WebKit's private `_WKInspector` for this web view, when available.
    public func cmuxInspectorObject() -> NSObject? {
        let selector = NSSelectorFromString("_inspector")
        guard responds(to: selector),
              let inspector = perform(selector)?.takeUnretainedValue() as? NSObject else {
            return nil
        }
        return inspector
    }

    /// The web view that renders this web view's Web Inspector frontend.
    public func cmuxInspectorFrontendWebView() -> WKWebView? {
        guard let inspector = cmuxInspectorObject() else { return nil }
        let selector = NSSelectorFromString("inspectorWebView")
        guard inspector.responds(to: selector),
              let inspectorWebView = inspector.perform(selector)?.takeUnretainedValue() as? WKWebView else {
            return nil
        }
        return inspectorWebView
    }

    /// Whether `responder` belongs to web content other than this page: this
    /// page's Web Inspector frontend, any Web Inspector view, or a view inside
    /// another web view. Page key routing must leave such responders alone.
    ///
    /// The inspector frontend is itself a web view, so the ancestor walk fails
    /// closed for it even when WebKit's class names change.
    public func cmuxResponderBelongsToOtherWebContent(_ responder: NSResponder?) -> Bool {
        guard let responder, responder !== self else { return false }
        if responder.cmuxIsInsideWebInspector {
            return true
        }
        guard let view = responder as? NSView else { return false }
        if let frontendWebView = cmuxInspectorFrontendWebView(),
           view === frontendWebView || view.isDescendant(of: frontendWebView) {
            return true
        }
        var node: NSView? = view
        while let current = node {
            if current === self { return false }
            if current is WKWebView { return true }
            node = current.superview
        }
        return false
    }
}

extension NSEvent {
    /// Whether this command equivalent should go straight to the main menu.
    ///
    /// Native window cycling (Cmd+` and the System Settings binding, each also
    /// with Shift) stays with AppKit so key-window changes do not re-enter the
    /// direct-to-menu shortcut path. The System Settings "Show Help menu"
    /// shortcut (Cmd+Shift+/ by default) also stays with AppKit, which opens
    /// the Help menu search only when no view claims the chord.
    public var cmuxRoutesDirectlyToMainMenu: Bool {
        guard modifierFlags.contains(.command) else { return false }
        return cmuxRoutesDirectlyToMainMenu(
            windowCyclingShortcut: SystemWindowCyclingShortcut.current(),
            helpMenuShortcut: SystemHelpMenuShortcut.current()
        )
    }

    /// Whether this command equivalent should go straight to the main menu,
    /// given the system's window-cycling and Help menu shortcuts.
    public func cmuxRoutesDirectlyToMainMenu(
        windowCyclingShortcut: SystemWindowCyclingShortcut?,
        helpMenuShortcut: SystemHelpMenuShortcut?
    ) -> Bool {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return false }

        let normalizedFlags = flags.subtracting([.numericPad, .function, .capsLock])
        if keyCode == 50,
           normalizedFlags == [.command] || normalizedFlags == [.command, .shift] {
            return false
        }
        // ISO keyboards and remapped System Settings cycle windows with another
        // key, such as the section key (keyCode 10).
        if windowCyclingShortcut?.matches(keyCode: keyCode, modifierFlags: flags) == true {
            return false
        }
        if helpMenuShortcut?.matches(keyCode: keyCode, modifierFlags: flags) == true {
            return false
        }

        return true
    }
}
