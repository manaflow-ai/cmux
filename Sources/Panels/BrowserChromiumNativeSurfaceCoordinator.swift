import AppKit
import CmuxChromium

/// Presents native `NSMenu` / `NSOpenPanel` for Chromium `<select>` popups and
/// file pickers, driven by surface-tree events from the shell.
@MainActor
final class BrowserChromiumNativeSurfaceCoordinator {
    private let session: ChromiumSession
    private weak var hostView: NSView?
    private var lastGeneration: UInt64 = 0
    private var didSelectMenuItem = false
    private var isPresenting = false

    init(session: ChromiumSession, hostView: NSView) {
        self.session = session
        self.hostView = hostView
    }

    func handle(_ tree: ChromiumSurfaceTree) {
        guard !isPresenting else { return }
        guard tree.generation != lastGeneration else { return }
        lastGeneration = tree.generation
        if let menu = tree.surfaces.first(where: { $0.kind == .nativeMenu && $0.visible }) {
            isPresenting = true
            presentMenu(menu)
        } else if let picker = tree.surfaces.first(where: { $0.kind == .nativeFilePicker && $0.visible }) {
            isPresenting = true
            presentFilePicker(picker)
        }
    }

    private func presentMenu(_ surface: ChromiumSurfaceInfo) {
        guard let hostView else {
            isPresenting = false
            return
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, item) in surface.nativeMenuItems.enumerated() {
            if item.separator {
                menu.addItem(.separator())
                continue
            }
            let menuItem = NSMenuItem(
                title: item.label,
                action: #selector(menuItemSelected(_:)),
                keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.tag = index
            menuItem.isEnabled = item.enabled
            if index == Int(surface.selectedIndex) { menuItem.state = .on }
            menu.addItem(menuItem)
        }
        let origin = NSPoint(
            x: CGFloat(surface.x),
            y: CGFloat(surface.y) + CGFloat(surface.height)
        )
        didSelectMenuItem = false
        menu.popUp(positioning: nil, at: origin, in: hostView)
        defer { isPresenting = false }
        if !didSelectMenuItem {
            Task { try? await session.cancelActivePopup() }
        }
    }

    @objc private func menuItemSelected(_ sender: NSMenuItem) {
        didSelectMenuItem = true
        let index = UInt32(sender.tag)
        Task { try? await session.acceptPopupMenuItem(at: index) }
    }

    private func presentFilePicker(_ surface: ChromiumSurfaceInfo) {
        guard let window = hostView?.window else {
            isPresenting = false
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = !surface.filePickerUploadFolder
        panel.canChooseDirectories = surface.filePickerUploadFolder
        panel.allowsMultipleSelection = surface.filePickerAllowsMultiple
        panel.beginSheetModal(for: window) { [session, weak self] response in
            let paths = panel.urls.map(\.path)
            Task { @MainActor in
                if response == .OK, !paths.isEmpty {
                    try? await session.selectFilePickerFiles(paths)
                } else {
                    try? await session.cancelActiveFilePicker()
                }
                self?.isPresenting = false
            }
        }
    }
}
