public import CmuxNextActions

/// Which modifier-hold chip text each pane of the focused screen gets: its Focus Pane 1…9 key,
/// then the key of every pane-navigation action (Focus Pane Left/Right/Above/Below, Previous/Next
/// Pane) that moves focus from the focused pane to it. One chip per pane, so a pane that is both
/// "pane 2" and "the pane to the right" never stacks two chips on one spot.
///
/// The keys come from `label`, which reads the window's resolved binding table (user rebinds,
/// keybindings.json removals, Ghostty keybinds); an action with no key under the held modifiers
/// gets no text. Pure: no AppKit, no registry.
public struct PaneNavigationHintPlan<Pane: Hashable> {
    /// Where a pane-navigation action moves focus from the focused pane.
    public enum Move: CaseIterable {
        case left, right, up, down, previous, next
    }

    /// The pane-navigation actions, in chip order after the pane's number.
    public static var actions: [(id: ActionID, move: Move)] {
        [("focusLeft", .left), ("focusRight", .right), ("focusUp", .up), ("focusDown", .down),
         ("focusPreviousPane", .previous), ("focusNextPane", .next)]
    }

    /// Every action whose key keeps the hints up while the modifier stays held (focus moves, the chips follow).
    public static var keepsHintsUp: Set<ActionID> { Set(actions.map(\.id) + ["focusPaneByNumber"]) }

    /// The screen's panes in Focus Next Pane order.
    public var order: [Pane]
    /// The pane that has focus.
    public var focused: Pane
    /// The pane each directional move reaches from `focused` (nil: no pane that way).
    public var neighbor: (Move) -> Pane?

    public init(order: [Pane], focused: Pane, neighbor: @escaping (Move) -> Pane?) {
        self.order = order
        self.focused = focused
        self.neighbor = neighbor
    }

    /// Chip text per pane, in `order`; panes with no key under the held modifiers are left out.
    ///
    /// - Parameter label: The key text for an action (with its 1…9 digit for Focus Pane 1…9), or nil.
    public func chips(label: (ActionID, Int?) -> String?) -> [(pane: Pane, text: String)] {
        var texts: [Pane: [String]] = [:]
        for (index, pane) in order.enumerated() where index < 8 || index == order.count - 1 {
            // 9 is always the last pane, as Focus Pane 1…9 picks it.
            let digit = index == order.count - 1 && index >= 8 ? 9 : index + 1
            if let text = label("focusPaneByNumber", digit) { texts[pane, default: []].append(text) }
        }
        let index = order.firstIndex(of: focused)
        for (id, move) in Self.actions {
            let target: Pane? = switch move {
            case .previous, .next:
                index.flatMap { order.count > 1 ? order[($0 + (move == .next ? 1 : -1) + order.count) % order.count] : nil }
            case .left, .right, .up, .down:
                neighbor(move)
            }
            guard let target, target != focused, let text = label(id, nil) else { continue }
            if texts[target]?.contains(text) != true { texts[target, default: []].append(text) }
        }
        return order.compactMap { pane in texts[pane].map { (pane, $0.joined(separator: " ")) } }
    }
}
