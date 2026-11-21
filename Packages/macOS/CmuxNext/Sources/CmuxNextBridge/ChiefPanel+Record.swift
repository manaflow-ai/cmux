public import CmuxNextDaemon
public import CmuxNextLayout

// The Chief panel in the window record (`WindowRecord.chiefPanel`): it reopens after a relaunch where it was.
extension ChiefPanel {
    /// The saved panel, always closed: a relaunch never shows the Chief until the person asks (cmux#37365). A
    /// floating panel at its first place when the record has none; a frame that is not four fractions in 0...1
    /// keeps the first place; an unknown placement floats.
    /// - Parameter record: The window record's panel, nil when it has none.
    public init(record: WindowChiefPanelRecord?) {
        self.init()
        guard let record else { return }
        placement = DockEdge(rawValue: record.placement).map(Placement.docked) ?? .floating
        if record.frame.count == 4, record.frame.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) {
            floatingFrame = ChiefPanelFrame(x: record.frame[0], y: record.frame[1], width: record.frame[2], height: record.frame[3])
        }
        dockExtentPermille = record.extentPermille
    }

    /// The record of this panel; nil for one never moved, docked or opened, so the window record stays as before.
    public var record: WindowChiefPanelRecord? {
        guard self != ChiefPanel() else { return nil }
        let f = floatingFrame
        return WindowChiefPanelRecord(open: isOpen, placement: dockedEdge?.rawValue ?? "floating",
                                      frame: [f.x, f.y, f.width, f.height], extentPermille: dockExtentPermille)
    }
}
