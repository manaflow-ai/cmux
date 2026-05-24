import CmuxExtensionKit
import Foundation

public struct DevServerSidebar: CmuxExtensionSidebarProvider {
    public let descriptor = CmuxExtensionSidebarProviderDescriptor(
        id: "com.example.cmux.sidebar.dev-servers",
        title: localized("example.sidebar.devServers.title", "Dev Servers"),
        subtitle: localized("example.sidebar.devServers.subtitle", "User extension"),
        systemImageName: "terminal",
        isHostProvided: false
    )

    public init() {}

    public func render(snapshot: CmuxExtensionSidebarSnapshot) -> CmuxExtensionSidebarRenderModel {
        let liveServers = snapshot.workspaces.filter(hasServerSignal)
        let remote = snapshot.workspaces.filter { workspace in
            !hasServerSignal(workspace) && trimmed(workspace.remoteDisplayTarget) != nil
        }
        let local = snapshot.workspaces.filter { workspace in
            !hasServerSignal(workspace) && trimmed(workspace.remoteDisplayTarget) == nil
        }

        let sections = [
            ExampleSidebarSection(
                id: "live",
                title: localized("example.sidebar.group.liveServers", "Live Servers"),
                systemImageName: "terminal",
                projectRootPath: nil,
                workspaces: liveServers
            )
            .render(subtitle: serverSubtitle),
            ExampleSidebarSection(
                id: "remote",
                title: localized("example.sidebar.group.remote", "Remote"),
                systemImageName: "network",
                projectRootPath: nil,
                workspaces: remote
            )
            .render(subtitle: serverSubtitle),
            ExampleSidebarSection(
                id: "local",
                title: localized("example.sidebar.group.local", "Local"),
                systemImageName: "folder",
                projectRootPath: nil,
                workspaces: local
            )
            .render(subtitle: serverSubtitle),
        ]

        return renderModel(providerId: descriptor.id, snapshot: snapshot, sections: sections)
    }

    private func hasServerSignal(_ workspace: CmuxExtensionWorkspaceSnapshot) -> Bool {
        if !workspace.listeningPorts.isEmpty {
            return true
        }
        guard let description = trimmed(workspace.customDescription)?.lowercased() else {
            return false
        }
        if description.contains("server") ||
            description.contains("http://") ||
            description.contains("https://") {
            return true
        }
        if description.range(of: #":\d{2,5}\b"#, options: .regularExpression) != nil {
            return true
        }
        if description.range(of: #"\bport\s*\d{2,5}\b"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private func serverSubtitle(_ workspace: CmuxExtensionWorkspaceSnapshot) -> CmuxExtensionSidebarRenderText? {
        if !workspace.listeningPorts.isEmpty {
            return .plain(workspace.listeningPorts.map { ":\($0)" }.joined(separator: ", "))
        }
        return trimmed(workspace.customDescription).map(CmuxExtensionSidebarRenderText.plain)
    }
}
