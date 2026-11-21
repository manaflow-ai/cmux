import AppKit
import CmuxNextDesign

/// Trackpad haptics for a drag reorder in the sidebar (https://github.com/manaflow-ai/cmux/issues/48598, as Aside does):
/// the alignment tap each time the drop slot changes, the level-change tap when the drop lands.
/// `sidebar.reorderHaptics` (on by default) turns both off. A trackpad without Force Touch plays nothing.
/// Each view that runs a drag owns one (`SidebarListView`, `SidebarRegionView`); a test sets `perform` to record.
struct SidebarReorderHaptics {
    /// What plays a tap: the system's performer.
    var perform: (NSHapticFeedbackManager.FeedbackPattern) -> Void = {
        NSHapticFeedbackManager.defaultPerformer.perform($0, performanceTime: .now)
    }

    /// The slot the drag last stood in; nil until it has one.
    private var slot: AnyHashable?

    /// A drag starts at `slot` (nil: it has none yet, and its first is noted with no tap).
    mutating func begin(at slot: AnyHashable?) { self.slot = slot }

    /// The drag's drop slot now. A change to another slot taps; nil (no drop here: the list keeps showing the last
    /// slot) taps nothing and keeps it. The first slot is where the drag starts, so it is noted without a tap.
    mutating func moved(to slot: AnyHashable?) {
        guard let slot, slot != self.slot else { return }
        let first = self.slot == nil
        self.slot = slot
        if !first { play(.alignment) }
    }

    /// A drop that moves something landed.
    func dropped() { play(.levelChange) }

    private func play(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard DesignSettings.shared.sidebarSections.reorderHaptics else { return }
        perform(pattern)
    }
}

extension SidebarListDrag {
    /// The place the list shows the drop now, so a tap is a change the eye sees: a group's slot, the top section the
    /// rows would join, or the list's gap or group fill and a block's gap. A document drag's own move is finer than
    /// that (a row's after zone and the next row's before zone are one gap), so it is not the key. Nil where nothing
    /// takes the drop.
    var hapticSlot: AnyHashable? {
        if let group { return group.drops[group.slot] == nil ? nil : AnyHashable(group.slot) }
        if let pinTarget { return AnyHashable(pinTarget) }
        guard target != nil || blockTarget != nil else { return nil }
        return AnyHashable(ShownSlot(target: target, block: blockTarget))
    }

    /// What the list draws for a drop: its gap or group fill, and a block's gap.
    private struct ShownSlot: Hashable {
        var target: DropTarget?
        var block: SidebarBlockGap?
    }
}
