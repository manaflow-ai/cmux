public import AppKit
public import CmuxMobileTerminalKit
public import SwiftUI

/// First-responder key capture for the remote terminal: an invisible AppKit
/// view that turns key presses into terminal input actions.
///
/// AppKit is the only complete source of raw key events (SwiftUI's `onKeyPress`
/// drops modifier detail), so this mirrors how the local terminal receives
/// keys — an NSView in the responder chain — while the mapping itself stays in
/// the pure ``HiveTerminalKeyMapping`` table.
public struct HiveTerminalInputView: NSViewRepresentable {
    /// Closure bundle for the capture view's actions (snapshot-boundary rule:
    /// the AppKit view holds closures, never a store).
    public struct Actions {
        var sendText: (String) -> Void
        var sendSpecial: (TerminalSpecialKey, TerminalKeyModifier) -> Void
        var sendControl: (String) -> Void

        public init(
            sendText: @escaping (String) -> Void,
            sendSpecial: @escaping (TerminalSpecialKey, TerminalKeyModifier) -> Void,
            sendControl: @escaping (String) -> Void
        ) {
            self.sendText = sendText
            self.sendSpecial = sendSpecial
            self.sendControl = sendControl
        }
    }

    private let actions: Actions
    private let isFocused: Bool

    /// Creates the input capture layer.
    /// - Parameters:
    ///   - actions: Where key input is routed.
    ///   - isFocused: When `true`, the view claims first responder.
    public init(actions: Actions, isFocused: Bool) {
        self.actions = actions
        self.isFocused = isFocused
    }

    public func makeNSView(context: Context) -> HiveTerminalKeyCaptureNSView {
        let view = HiveTerminalKeyCaptureNSView()
        view.actions = actions
        return view
    }

    public func updateNSView(_ nsView: HiveTerminalKeyCaptureNSView, context: Context) {
        nsView.actions = actions
        if isFocused, nsView.window?.firstResponder !== nsView {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

/// The AppKit key-capture view backing ``HiveTerminalInputView``.
public final class HiveTerminalKeyCaptureNSView: NSView {
    var actions: HiveTerminalInputView.Actions?

    override public var acceptsFirstResponder: Bool { true }

    override public func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override public func keyDown(with event: NSEvent) {
        // Cmd+V pastes into the remote PTY; every other Command chord stays
        // with the app (the mapping returns nil for Command).
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            if let pasted = NSPasteboard.general.string(forType: .string), !pasted.isEmpty {
                actions?.sendText(pasted)
            }
            return
        }
        guard let action = HiveTerminalKeyMapping.action(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags
        ) else {
            super.keyDown(with: event)
            return
        }
        switch action {
        case .special(let key, let modifiers):
            actions?.sendSpecial(key, modifiers)
        case .control(let character):
            actions?.sendControl(character)
        case .text(let text):
            actions?.sendText(text)
        }
    }
}
