public import AppKit

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

extension NSEvent {
    /// Whether this command equivalent should go straight to the main menu.
    ///
    /// Native window cycling (Cmd+` and the System Settings binding, each also
    /// with Shift) stays with AppKit so key-window changes do not re-enter the
    /// direct-to-menu shortcut path.
    public var cmuxRoutesDirectlyToMainMenu: Bool {
        guard modifierFlags.contains(.command) else { return false }
        return cmuxRoutesDirectlyToMainMenu(windowCyclingShortcut: SystemWindowCyclingShortcut.current())
    }

    /// Whether this command equivalent should go straight to the main menu,
    /// given the system's window-cycling shortcut.
    public func cmuxRoutesDirectlyToMainMenu(windowCyclingShortcut: SystemWindowCyclingShortcut?) -> Bool {
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

        return true
    }
}
