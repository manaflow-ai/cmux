public import AppKit

extension AgentPaneView {
    /// Types the text of `event`, a key the New Tab key hold kept for this pane's ready field, into
    /// the page through its input bridge while cmux is not the active app.
    ///
    /// While the app is not active no window is key. Chromium drops a key event sent to a page window
    /// that is not key, and the unfocused document sends no focus events, so the page's input
    /// readiness never turns ready and the key router's type-ahead would keep the key for good: the
    /// field had the caret but stayed empty (a script's or a background Cmd-T lost its first keys, a
    /// `/` for the slash menu included). The text goes into the focused field with
    /// ``PageInputReadiness/insert(_:expectedEpoch:)``, after the text of the keys before it
    /// (``heldKeyTyping``). Any other key, and every key while the app is active (the person's path,
    /// where the page window is key), stays a key event.
    ///
    /// - Parameters:
    ///   - event: The held key.
    ///   - appIsActive: Whether cmux is the active app (injected for tests).
    /// - Returns: Whether the page took the key's text; false: the caller sends the key event on.
    @discardableResult
    public func typeHeldText(of event: NSEvent, appIsActive: Bool = NSApp.isActive) -> Bool {
        guard !appIsActive, chromiumPage != nil, let text = typedText(of: event) else { return false }
        let before = heldKeyTyping
        heldKeyTyping = Task { [inputReadiness] in
            await before?.value
            _ = await inputReadiness.insert(text)
        }
        return true
    }

    /// The agent pane in `window` whose Chromium page shows in `pageWindow` (a child window of
    /// `window`), found by the page window's center; nil when no pane's page covers it.
    ///
    /// - Parameters:
    ///   - pageWindow: A Chromium page window.
    ///   - window: The cmux window it is a child of.
    /// - Returns: The pane, or nil.
    public static func showing(chromiumPageWindow pageWindow: NSWindow, in window: NSWindow) -> AgentPaneView? {
        let center = CGPoint(x: pageWindow.frame.midX, y: pageWindow.frame.midY)
        var stack: [NSView] = window.contentView.map { [$0] } ?? []
        while let view = stack.popLast() {
            if let pane = view as? AgentPaneView, let content = pane.chromiumPage?.contentView, let host = content.window,
               host.convertToScreen(content.convert(content.bounds, to: nil)).contains(center) { return pane }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }
}

/// The text `event` types: a key down with no Command, Control or Function modifier whose characters
/// are all printable (no Return, Tab, Escape, Delete or arrow); nil for any other key.
private func typedText(of event: NSEvent) -> String? {
    guard event.type == .keyDown, event.modifierFlags.isDisjoint(with: [.command, .control, .function]),
          let text = event.characters, !text.isEmpty else { return nil }
    let printable = text.unicodeScalars.allSatisfy { scalar in
        !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
    }
    return printable ? text : nil
}
