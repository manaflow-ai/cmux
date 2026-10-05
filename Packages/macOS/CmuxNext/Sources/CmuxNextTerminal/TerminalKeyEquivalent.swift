public import AppKit
import GhosttyNextKit

/// A terminal's key equivalents, which reach it before the main menu
/// (split from `TerminalSurfaceView`). Ghostty keybinds run here, except
/// that a cmux menu item with the same chord wins (the app's menu gate
/// refuses a key its dispatcher already decided), so cmux shortcuts are
/// never shadowed by Ghostty defaults such as `cmd+t`. Unbound Command and
/// Control chords go back through `keyDown` after AppKit had its chance.
public struct TerminalKeyEquivalent {
    public let view: TerminalSurfaceView

    /// Notes the path of a traced key (`debug.key`); nil otherwise.
    public static var trace: ((String) -> Void)?

    public init(view: TerminalSurfaceView) {
        self.view = view
    }

    public func perform(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, view.isFirstResponder, let surface = view.surface else { return false }

        var flags = ghostty_binding_flags_e(rawValue: 0)
        var keyEvent = GhosttyInput.keyEvent(event, action: GHOSTTY_ACTION_PRESS)
        let isBinding = (event.characters ?? "").withCString { pointer in
            keyEvent.text = pointer
            return ghostty_surface_key_is_binding(surface, keyEvent, &flags)
        }
        Self.trace?("terminal: Ghostty binding \(isBinding ? "yes" : "no")")
        if isBinding {
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                Self.trace?("terminal: the menu took it")
                return true
            }
            Self.trace?("terminal: keyDown to Ghostty")
            view.keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // Ctrl-Return goes to the terminal instead of the default button.
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            // Ctrl-/ is Ctrl-_ in terminals; AppKit would beep.
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            equivalent = "_"
        default:
            // Synthetic events (zero timestamp) come from AppKit key
            // bindings such as Cmd-. -> cancel; never encode those.
            guard event.timestamp != 0 else { return false }
            guard !event.modifierFlags.isDisjoint(with: [.command, .control]) else {
                view.lastPerformKeyEventTimestamp = nil
                return false
            }
            // Second pass for the same event: nothing in AppKit claimed it,
            // so encode it for the terminal.
            if let previous = view.lastPerformKeyEventTimestamp {
                view.lastPerformKeyEventTimestamp = nil
                if previous == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }
            view.lastPerformKeyEventTimestamp = event.timestamp
            return false
        }

        guard let rewritten = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) else { return false }
        view.keyDown(with: rewritten)
        return true
    }
}
