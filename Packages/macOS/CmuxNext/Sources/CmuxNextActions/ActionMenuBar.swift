public import AppKit

/// The main menu bar. A key-down the key router decided, whose chord's items are all registry items the menu
/// gate refuses (``ActionRegistry/menuKeyEquivalentGate``: no system action), is not searched, and the same
/// event's second pass (`NSApplication`'s, after the terminal's own) returns at once: the router already
/// resolved it, as Chrome's `CommandDispatcher` answers the redispatch of a key it handled with NO
/// (ui/base/cocoa/command_dispatcher.mm, `-performKeyEquivalent:`). The key goes on to the focused view, as
/// a chord with no menu item does. A chord that a responder item (Copy, Undo, Hide), a system item (Quit) or
/// an item the bar does not make shares keeps AppKit's search, and so does every undecided key and a click.
///
/// The macOS 26 SDK declares `NSMenu`'s `init(coder:)` and `performKeyEquivalent(with:)` nonisolated, so their
/// overrides are too. The bar's state stays on the main actor: the key work runs there, on the main thread
/// AppKit dispatches keys on, and reads the key-down from the registry (``ActionRegistry/dispatchingInputEvent``),
/// matched by identity to the one AppKit hands the bar, so no event crosses actors. A key-down that is not the
/// one being dispatched keeps AppKit's search.
public final class ActionMenuBar: NSMenu {
    /// A key equivalent as AppKit matches it: the lowercased key and the modifiers.
    nonisolated struct Chord: Equatable {
        let key: String
        let modifiers: UInt

        static let modifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

        /// An item's: a capital key equivalent means Shift.
        init(item: NSMenuItem) {
            let lowered = item.keyEquivalent.lowercased()
            var modifiers = item.keyEquivalentModifierMask.intersection(Self.modifierMask)
            if lowered != item.keyEquivalent { modifiers.insert(.shift) }
            key = lowered
            self.modifiers = modifiers.rawValue
        }

        /// A key-down's: Shift only from its flags (Caps Lock capitalizes a key without Shift).
        init?(_ event: NSEvent) {
            guard let key = event.charactersIgnoringModifiers, !key.isEmpty else { return nil }
            self.key = key.lowercased()
            modifiers = event.modifierFlags.intersection(Self.modifierMask).rawValue
        }
    }

    private weak var registry: ActionRegistry?
    /// Whether the key router decided a key-down (the App's `KeyRouter.decided`).
    private nonisolated let decidedKey: @MainActor (NSEvent) -> Bool
    /// The key-down the bar last refused: the same event's second pass asks nothing again.
    private weak var refusedEvent: NSEvent?

    public init(registry: ActionRegistry, decidedKey: @escaping @MainActor (NSEvent) -> Bool) {
        self.registry = registry
        self.decidedKey = decidedKey
        super.init(title: "")
    }

    public nonisolated required init(coder: NSCoder) {
        decidedKey = { _ in false }
        super.init(coder: coder)
    }

    // perf-hot: 0.5ms key-dispatch (every chord no view took)
    public nonisolated override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, Thread.isMainThread else { return super.performKeyEquivalent(with: event) }
        // The event is alive for this call, so its identifier names it alone until the call returns.
        let keyDown = ObjectIdentifier(event)
        // main-proof: the guard above returned unless this runs on the main thread.
        if MainActor.assumeIsolated({ refusesSearch(for: keyDown) }) { return false }
        return super.performKeyEquivalent(with: event)
    }

    /// Whether the bar refuses to search for the key-down `keyDown` (it records the refusal; its second pass is
    /// refused at once), and counts the search AppKit runs otherwise. Only the key-down being dispatched
    /// (``ActionRegistry/dispatchingInputEvent``) is refused. False without a registry.
    private func refusesSearch(for keyDown: ObjectIdentifier) -> Bool {
        if let refusedEvent, ObjectIdentifier(refusedEvent) == keyDown { return true }
        guard let registry else { return false }
        if let event = registry.dispatchingInputEvent(), ObjectIdentifier(event) == keyDown, decidedKey(event),
           let chord = Chord(event), registry.refusesEveryKeyEquivalent(of: Self.items(matching: chord, in: self)) {
            refusedEvent = event
            registry.menuTarget.counters.skipped += 1
            return true
        }
        if registry.isDispatchingKeyDown() { registry.menuTarget.counters.searches += 1 }
        return false
    }

    /// The items of `menu` and its submenus with `chord` as their key equivalent, read now: a menu built
    /// later (the Window list, a Debug submenu) is in it too.
    private static func items(matching chord: Chord, in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            let nested = item.submenu.map { items(matching: chord, in: $0) } ?? []
            guard !item.keyEquivalent.isEmpty, Chord(item: item) == chord else { return nested }
            return nested + [item]
        }
    }
}

/// The main menu's key-equivalent work during key-downs since launch (`debug.key` reports one key's).
public struct MenuKeyEquivalentCounters: Sendable, Equatable {
    /// Searches of the menu bar AppKit ran.
    public var searches = 0
    /// Searches the bar refused (``ActionMenuBar``): every item of the chord is a registry item the gate refuses.
    public var skipped = 0
    /// Registry items AppKit validated.
    public var validations = 0

    public init(searches: Int = 0, skipped: Int = 0, validations: Int = 0) {
        self.searches = searches
        self.skipped = skipped
        self.validations = validations
    }
}

extension ActionRegistry {
    /// The main menu's key-equivalent searches, refusals and validations during key-downs since launch.
    public var menuKeyEquivalentCounters: MenuKeyEquivalentCounters { menuTarget.counters }

    /// Whether a key-down refuses every one of `items` (one chord's main-menu items): each is a registry item
    /// that no key window route claims and whose key equivalent the menu gate refuses now, so its
    /// `validateMenuItem` would return false. False for no items, outside a key-down and without a gate.
    func refusesEveryKeyEquivalent(of items: [NSMenuItem]) -> Bool {
        guard !items.isEmpty, let gate = menuKeyEquivalentGate, isDispatchingKeyDown() else { return false }
        return items.allSatisfy { item in
            guard let raw = item.representedObject as? String else { return false }
            let id = ActionID(rawValue: raw)
            return keyWindowRoute?(canonicalID(for: id), ActionInvocation()) == nil && !gate(id)
        }
    }
}
