import AppKit
import CmuxNextSidebar

// An anchor at a machine's sidebar header: the icon picker of a machine's
// icon opens beside the header the user right-clicked.
extension IconPickerService {
    /// An anchor at machine `id`'s section header in the active window's
    /// sidebar, else the top middle of the active window (a lone machine's
    /// list draws no header).
    func anchor(machine id: String) -> Anchor? {
        guard let controller = services?.windows.active, let content = controller.window?.contentView else { return nil }
        let section = SectionID.machine(CmuxNextSidebar.MachineID(id))
        if let screen = controller.sidebar.container.sidebarView.sectionRowFrameOnScreen(for: section), let window = content.window {
            return Anchor(view: content, rect: content.convert(window.convertFromScreen(screen), from: nil))
        }
        return activeWindowAnchor()
    }
}
