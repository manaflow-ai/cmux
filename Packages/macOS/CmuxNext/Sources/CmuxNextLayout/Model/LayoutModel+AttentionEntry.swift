public import CmuxNextDesign

/// The attention ring's dismiss blink, driven by the pane focus itself
/// (https://github.com/manaflow-ai/cmux/issues/46908). Focusing a ringing pane
/// blinks its ring out in the same pass, whatever the pane's content is doing:
/// an agent chat still loading has no page window holding the keys yet, so the
/// App's viewed-tab rules may read the tab only later, and a pass in between
/// may not say it was read by going in. Neither decides the blink any more.
extension LayoutModel {
    /// The App's attention marks. `readByEntry`: panes whose mark this change removes because the
    /// person went into them. A pane the focus entered keeps its ring out while its generation holds.
    public func setAttention(_ marks: [PaneID: AttentionMark], readByEntry: Set<PaneID>) {
        attentionMarks = marks
        enteredAttention = enteredAttention.filter { marks[$0.key]?.generation == $0.value }
        let shown = marks.filter { enteredAttention[$0.key] == nil }
        // A ring that went by entry blinks whenever the chrome draws it going; it leaves the set when it rings again.
        let read = attentionReadByEntry.union(readByEntry).subtracting(shown.keys)
        if attentionReadByEntry != read { attentionReadByEntry = read }
        if attention != shown { attention = shown }
    }

    /// The person went into `pane` (the focus moved into it, or `click`): a ring the App reads so goes
    /// now, in the pass that moves the focus or takes the click, not when the read comes back or the
    /// pane's content loads; it blinks out unless the flash is off (`notifications.attention.flash`). True when it did.
    @discardableResult
    public func enterAttention(_ pane: PaneID, click: Bool = false) -> Bool {
        guard let mark = attention[pane], readsAttentionOnEntry(pane, click) else { return false }
        enteredAttention[pane] = mark.generation
        if DesignSettings.shared.attention.flashesOnRead { attentionReadByEntry.insert(pane) }
        attention[pane] = nil
        return true
    }
}
