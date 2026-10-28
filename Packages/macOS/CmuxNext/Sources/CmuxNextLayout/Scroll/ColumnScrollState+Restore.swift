import CoreGraphics

/// A remounted screen's camera: the offset its workspace showed when it unmounted,
/// as Chrome's renderer restores a discarded tab's scroll offset from its `PageState` before the
/// first paint (third_party/blink/renderer/core/loader/history_item.h, `HistoryItem::GetViewState`).
nonisolated extension ColumnScrollState {
    /// Takes `strip` and `focused` as the first sync does, rests at `offset` (clamped to the strip),
    /// then reveals the focused pane the least (a layout change while unmounted may have moved it
    /// out of view). No frames: the remount's first frame already shows the restored camera.
    mutating func restoreCamera(at offset: CGFloat, strip new: ColumnStrip, focused: PaneID?) {
        strip = new
        focusedPane = focused
        let index = focused.flatMap(new.index(ofPane:))
        focusedColumn = index.map { new.columns[$0].id }
        remembered = [:]
        if let focused, let focusedColumn { remembered[focusedColumn] = focused }
        restore = nil
        revealDeferred = false
        var target = new.clamp(offset)
        if let index {
            target = ColumnViewOffset.target(column: index, pane: focused, current: target, mode: .never, previous: nil, strip: new)
        }
        spring.snap(to: new.clamp(target))
    }
}
