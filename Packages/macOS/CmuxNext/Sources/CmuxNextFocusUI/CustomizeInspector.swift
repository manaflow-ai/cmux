public import AppKit
public import CmuxNextActions
public import CmuxNextDesign

/// The Customize Inspector: hold Option and move the pointer over the window, and the big part
/// under it (the Rust element map's entry, ``CustomizeElement``) gets an outline and a card with
/// its name, the settings that change it and the theme colors it paints with, plus Change This…
/// (a chat about that part, `customize.open` with its `element`) and Reset (its settings back to
/// their defaults). Leo, 2026-11-14: "the ergonomics need to be real good like just ultra braindead".
///
/// It never takes input from the window: the outline passes every click through, and a key or a
/// click outside the card ends it, as the shortcut hints do. Only the card takes the mouse, and
/// while the pointer is on it the element stays put, so its buttons can be reached with Option
/// still held or after letting go.
@MainActor
public final class CustomizeInspector {
    /// What the inspector asks of the app: the element map, and the two things its buttons do.
    public struct Actions {
        public var element: (String) -> CustomizeElement?
        /// Change This…: a chat about `element`.
        public var change: (CustomizeElement) -> Void
        /// Reset: `element`'s settings back to their defaults.
        public var reset: (CustomizeElement) -> Void

        public init(element: @escaping (String) -> CustomizeElement? = CustomizeElement.named,
                    change: @escaping (CustomizeElement) -> Void, reset: @escaping (CustomizeElement) -> Void) {
            (self.element, self.change, self.reset) = (element, change, reset)
        }
    }

    private weak var window: NSWindow?
    private let actions: Actions
    /// Pointer moves and scrolls, watched only while Option is held or the card shows.
    private var pointerMonitor: Any?
    private var outline: (view: CustomizeInspectorOutlineView, handle: OverlayHandle)?
    private var card: (view: CustomizeInspectorCardView, handle: OverlayHandle)?
    /// The element shown, in window coordinates.
    public private(set) var shown: (element: CustomizeElement, frame: NSRect)?

    public init(window: NSWindow, actions: Actions) {
        self.window = window
        self.actions = actions
    }

    /// Whether `flags` hold Option and nothing else that shortcuts use (Shift, Command, Control
    /// mean a chord, not the inspector).
    public nonisolated static func holdsInspector(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .control, .shift, .option]) == .option
    }

    /// The window's intentional modifier hold changed (the shortcut hints' monitor: 0.3 s held, in
    /// the key window, and on only while `DesignSettings.showModifierHoldHints` is). `flags` nil is
    /// a release, a key, a click or the window losing key: it ends the inspector unless the pointer
    /// is on the card in the key window, whose buttons stay reachable after letting go.
    public func holdChanged(_ flags: NSEvent.ModifierFlags?) {
        guard let flags, Self.holdsInspector(flags), let window else {
            if window?.isKeyWindow != true || !pointerOnCard(atScreen: NSEvent.mouseLocation) { end() }
            return
        }
        watchPointer()
        pointerMoved(to: window.mouseLocationOutsideOfEventStream)
    }

    private func watchPointer() {
        guard pointerMonitor == nil else { return }
        pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .scrollWheel]) { [weak self] event in
            self?.receive(event)
            return event
        }
    }

    private func receive(_ event: NSEvent) {
        guard let window, event.window === window || event.window == nil else { return }
        let point = event.window === window ? event.locationInWindow : window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let onCard = pointerOnCard(atScreen: window.convertPoint(toScreen: point))
        // The event's own flags: a move synthesized for a tour (debug.mouse) holds Option too.
        if event.type == .mouseMoved, Self.holdsInspector(event.modifierFlags) {
            if !onCard { pointerMoved(to: point) }
        } else if !onCard {
            end()
        }
    }

    private func pointerOnCard(atScreen point: NSPoint) -> Bool {
        guard let view = card?.view, let cardWindow = view.window else { return false }
        return view.convert(view.bounds, to: nil).contains(cardWindow.convertPoint(fromScreen: point))
    }

    private func pointerMoved(to point: NSPoint) {
        guard let window else { return }
        guard let hit = CustomizeElementHit.resolve(in: window, at: point), let element = actions.element(hit.id) else {
            return end()
        }
        show(element, frame: hit.frame)
    }

    /// Shows `element` at `frame` (window coordinates): the outline and the card beside it. Tests
    /// call it to show an element with no pointer.
    public func show(_ element: CustomizeElement, frame: NSRect) {
        guard let window, shown?.element != element || shown?.frame != frame else { return }
        shown = (element, frame)
        let host = WindowOverlayHost.host(for: window)
        if let outline {
            outline.view.setFrameSize(frame.size)
            outline.handle.update(anchor: frame)
        } else {
            let view = CustomizeInspectorOutlineView(frame: NSRect(origin: .zero, size: frame.size))
            outline = (view, host.present(view, options: OverlayOptions(kind: .dragGhost, anchor: frame)))
        }
        let cardView = card?.view ?? CustomizeInspectorCardView()
        cardView.show(element, change: { [weak self] in
            self?.end()
            self?.actions.change(element)
        }, reset: { [weak self] in
            self?.end()
            self?.actions.reset(element)
        })
        if let card {
            card.handle.update(anchor: frame)
        } else {
            card = (cardView, host.present(cardView, options: OverlayOptions(kind: .popover, anchor: frame, passesThroughClicks: false)))
        }
    }

    /// Takes the outline and the card down and stops watching the pointer.
    public func end() {
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
        guard shown != nil || outline != nil || card != nil else { return }
        shown = nil
        let handles = [outline?.handle, card?.handle].compactMap { $0 }
        (outline, card) = (nil, nil)
        for handle in handles { handle.dismiss() }
    }
}
