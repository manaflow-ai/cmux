import AppKit
import CmuxNextControl
import CmuxNextDesign

/// Metadata supplied by the window capture owner only after publishing the image.
struct LaunchRecordImage: Sendable {
    let path: String
    let pixelWidth: UInt32
    let pixelHeight: UInt32
}

/// Adapts the live window/sidebar state to the bounded Rust record. No disk read
/// or daemon connection is started while taking a snapshot.
@MainActor
final class AppLaunchRecord {
    private unowned let services: AppServices
    private var images: [String: LaunchRecordImage] = [:]
    private lazy var writer: LaunchRecordWriter? = {
        guard let bundleID = services.environment.launch.bundleID else { return nil }
        let url = LaunchTimesFile.supportDirectory(bundleID: bundleID)
            .appending(path: "launch-record.bin", directoryHint: .notDirectory)
        return LaunchRecordWriter(url: url, work: services.work) { [weak self] in
            guard let self else { return nil }
            // Read an already-connected endpoint; endpoint() could wait for a daemon to start.
            let socket = await services.daemon.connection?.endpoint?.socketPath ?? ""
            return snapshot(socket: socket)
        }
    }()

    init(services: AppServices) { self.services = services }

    func setImage(_ image: LaunchRecordImage?, forWindow id: String) {
        images[id] = image
        schedule()
    }

    func schedule() {
        guard services.windows.restored else { return }
        writer?.schedule()
    }
    func flush() async {
        guard services.windows.restored else { return }
        await writer?.flush()
    }

    private func snapshot(socket: String) -> LaunchRecordSnapshot {
        let manager = services.windows
        let front = manager.active
        let controllers = manager.controllers.filter { !manager.isIncognito(window: $0.state.id) }
        let ordered = controllers.filter { $0 === front } + controllers.filter { $0 !== front }
        let shown = Set(ordered.flatMap { $0.mountedContents.filter { !$0.isParked }.map { $0.workspace.id } })
        var seen = Set<String>()
        let sidebars = ordered.flatMap { controller in
            let model = controller.sidebar.model
            let sidebar = SidebarSnapshot(sections: model.sections, profiles: model.profiles, activeProfileID: model.activeProfileID)
            return sidebar.sections.flatMap(\.nodes).flatMap { $0.workspace.map { [$0] } ?? $0.group?.workspaces ?? [] }
        }.filter { !shown.contains($0.id) && seen.insert($0.id).inserted }
            .map { LaunchRecordSidebarSnapshot(id: $0.id, title: $0.title, iconKey: $0.icon ?? "") }
        let windows = ordered.compactMap { controller -> LaunchRecordWindowSnapshot? in
            guard let window = controller.window else { return nil }
            let image = images[controller.state.id]
            let color = controller.themeScope.tokens.surfaceBackground
            let rgba = (Self.byte(color.red), Self.byte(color.green), Self.byte(color.blue), Self.byte(color.alpha))
            let tabs = controller.mountedContents.filter { !$0.isParked }.flatMap { content in
                content.panes.values.filter { !$0.view.isHiddenOrHasHiddenAncestor }.compactMap { $0.stripModel.selectedID?.rawValue }
            }
            let display = (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            // WindowRootView paints the titlebar and the body with the same surface token.
            return LaunchRecordWindowSnapshot(id: controller.state.id, frame: window.frame, displayID: display,
                backgroundRGBA: rgba, barRGBA: rgba, imagePath: image?.path ?? "",
                imagePixelSize: (image?.pixelWidth ?? 0, image?.pixelHeight ?? 0),
                workspaceID: controller.state.workspaceID ?? "", tabIDs: tabs)
        }
        return LaunchRecordSnapshot(windows: windows, sidebarRows: sidebars, sessionSocketPath: socket)
    }

    private static func byte(_ component: Double) -> UInt8 {
        UInt8(clamping: Int((min(1, max(0, component)) * 255).rounded()))
    }
}
