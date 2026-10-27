import AppKit
import CmuxNextBrowser
import CmuxNextFocusUI

/// Hint mode (`hints.show`, Cmd-J; cx-zjtn.1): every clickable control in
/// the window gets a one or two letter label (``LinkHintSession``'s Vimium
/// labels) and typing a whole label clicks that control, as the person's own
/// click. The controls come from the window's accessibility tree
/// (``WindowHintTargets``) and, for first-party web pages, from the link
/// hint script; labels show once the pages answer (keys typed before that
/// wait for them). Typing a label's last letter with Shift
/// right-clicks the control instead, so every context menu opens from the
/// keyboard. The key router hands this controller every key while labels
/// show; Escape, a chord, any other key, a click or another window ends it.
/// A preview feature (`labs.previewFeatures`) until styled.
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

    /// Asking the pages for their targets; the keys typed meanwhile.
    private struct Pending {
        let query: PageCollection
        weak var window: NSWindow?
        var keys: [NSEvent] = []
    }

    private var session: Session? { didSet { noteActive() } }
    private var pending: Pending? { didSet { noteActive() } }

    var isActive: Bool { session != nil || pending != nil }

    /// The key router's modes: while labels show or wait, the router asks this controller first for typing keys too
    /// (``KeyRouterMode/windowHints``). `AppServices` passes the router's instance.
    var keyModes: KeyRouterModes? { didSet { noteActive() } }

    private func noteActive() { keyModes?.set(.windowHints, isActive) }

    /// Labels the controls of `controller`'s window, or ends a session that
    /// shows (the action toggles). Returns false when nothing is clickable.
    @discardableResult
    func toggle(in controller: WindowController) -> Bool {
        guard !isActive else {
            cancel()
            return true
        }
        guard let window = controller.window, let content = window.contentView else { return false }
        let found = WindowHintTargets.collect(in: content)
        guard !found.pages.isEmpty else { return show(found.targets, in: controller) }
        // The labels show when the pages answered or the person's userBlocking deadline ended the wait.
        let query = WindowHintTargets.pageTargets(of: found.pages, clip: found.bounds,
                                                  deadlines: controller.services.mainDeadlines) { [weak self, weak controller] pages in
            guard let self, let controller, let waiting = self.pending else { return }
            self.pending = nil
            let targets = found.targets + pages
            guard self.show(Array(targets.prefix(WindowHintTargets.limit)), in: controller) else { return }
            for event in waiting.keys where self.session != nil { _ = self.interceptKeyDown(event, in: waiting.window) }
        }
        pending = Pending(query: query, window: window)
        return true
    }

    private func show(_ targets: [WindowHintTargets.Target], in controller: WindowController) -> Bool {
        guard let window = controller.window else { return false }
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
        if pending != nil, session == nil {
            // Escape or another window ends the wait; anything else waits for the labels.
            guard event.keyCode != 53, window === pending?.window else {
                cancel()
                return event.keyCode == 53
            }
            pending?.keys.append(event)
            return true
        }
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
            let menu = event.modifierFlags.contains(.shift)
            if let page = hint?.target.page {
                page.click(menu: menu)
            } else if let hint {
                Self.click(at: hint.target.center, in: home, menu: menu)
            }
        }
        return true
    }

    func cancel() {
        pending?.query.cancel()
        pending = nil
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
    /// `menu`: a right mouse down alone, which opens the context menu and
    /// leaves it open for the keyboard (an up could pick the item under it).
    private static func click(at point: NSPoint, in window: NSWindow, menu: Bool = false) {
        let time = ProcessInfo.processInfo.systemUptime
        for type in menu ? [NSEvent.EventType.rightMouseDown] : [.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { continue }
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
