import AppKit
import CmuxNextBrowser

/// Hint mode (`hints.show`, Cmd-J; cx-zjtn.1): every clickable control in
/// the window gets a one or two letter label (``LinkHintSession``'s Vimium
/// labels) and typing a whole label clicks that control, as the person's own
/// click. The controls come from the window's accessibility tree
/// (``WindowHintTargets``). The key router hands this controller every key
/// while labels show; Escape, a chord, any other key, a click or another
/// window ends it. A preview feature (`labs.previewFeatures`) until styled.
@MainActor
final class WindowHintController {
    struct Hint: Equatable {
        var label: String
        var target: WindowHintTargets.Target
    }

    private struct Session {
        var keys: LinkHintSession
        weak var window: NSWindow?
        let overlay: ShortcutHintOverlayView
        var hints: [Hint]
    }

    private var session: Session?

    var isActive: Bool { session != nil }

    /// Labels the controls of `controller`'s window, or ends a session that
    /// shows (the action toggles). Returns false when nothing is clickable.
    @discardableResult
    func toggle(in controller: WindowController) -> Bool {
        guard session == nil else {
            cancel()
            return true
        }
        guard let window = controller.window, let content = window.contentView else { return false }
        let targets = WindowHintTargets.collect(in: content)
        var keys = LinkHintSession(mode: .follow)
        guard keys.show(targets.map(\.point)) != .cancel, let labelled = keys.hints else { return false }
        let hints = zip(labelled, targets).map { Hint(label: $0.0.label, target: $0.1) }
        let overlay = ShortcutHintOverlayView()
        overlay.setAccessibilityElement(false)
        overlay.frame = controller.root.bounds
        overlay.autoresizingMask = [.width, .height]
        controller.root.addSubview(overlay, positioned: .above, relativeTo: nil)
        session = Session(keys: keys, window: window, overlay: overlay, hints: hints)
        draw(prefix: "")
        return true
    }

    /// Every key-down while labels show (``KeyRouter`` asks first). Returns
    /// whether the key was consumed; a key that ends the session without
    /// being a hint key goes on to the focused view.
    func interceptKeyDown(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard var current = session, let home = current.window, window === home else {
            cancel()
            return false
        }
        if event.keyCode == 53 {
            cancel()
            return true
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        let outcome: LinkHintSession.Outcome
        if flags.isEmpty, event.keyCode == 51 {
            outcome = current.keys.type(nil)
        } else if flags.isEmpty, let letter = event.charactersIgnoringModifiers?.lowercased(), letter.count == 1,
                  letter.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) }) {
            outcome = current.keys.type(letter)
        } else {
            cancel()
            return false
        }
        session = current
        switch outcome {
        case .cancel:
            cancel()
        case .narrow(let prefix):
            draw(prefix: prefix)
        case .pick(let picked):
            let hint = current.hints.first { $0.target.point == picked }
            cancel()
            if let hint { Self.click(at: hint.target.center, in: home) }
        }
        return true
    }

    func cancel() {
        session?.overlay.removeFromSuperview()
        session = nil
    }

    /// The labels that start with `prefix`, in the overlay.
    private func draw(prefix: String) {
        guard let current = session, let root = current.overlay.superview else { return }
        current.overlay.hints = current.hints.filter { $0.label.hasPrefix(prefix) }.map { hint in
            ShortcutHintOverlayView.Hint(text: hint.label.uppercased(), rect: root.convert(hint.target.rect, from: nil))
        }
    }

    /// A click at `point` (window coordinates), queued like the person's
    /// own: a control that tracks the mouse after the down finds the up.
    private static func click(at point: NSPoint, in window: NSWindow) {
        let time = ProcessInfo.processInfo.systemUptime
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// What is typed and every label, while labels show (`debug.hints`).
    var shown: (typed: String, hints: [Hint])? {
        session.map { ($0.keys.typed, $0.hints) }
    }
}

enum WindowHintStrings {
    static var preview: String {
        String(localized: "windowHints.refusal.preview", defaultValue: "Click by Hint is a preview feature: turn on labs.previewFeatures in cmux.json.",
               table: "LinkHints", bundle: .module)
    }

    static var nothing: String {
        String(localized: "windowHints.refusal.nothing", defaultValue: "Nothing to click in this window.", table: "LinkHints", bundle: .module)
    }
}
