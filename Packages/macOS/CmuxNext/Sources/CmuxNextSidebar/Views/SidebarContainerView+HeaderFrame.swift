#if DEBUG
public import AppKit

// `debug.daemon_update` (captures): where a machine section header sits, so a synthetic hover opens its tooltip.
public extension SidebarContainerView {
    /// The header row of `machine`'s section in window coordinates; nil when it is not drawn.
    func machineHeaderFrameInWindow(_ machine: MachineID) -> NSRect? {
        let list = sidebarView.list
        list.layoutSubtreeIfNeeded()
        guard let row = list.displayed.row(for: .section(.machine(machine))) else { return nil }
        return list.convert(list.frame(for: row), to: nil)
    }
}
#endif
