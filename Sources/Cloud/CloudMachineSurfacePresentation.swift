import Foundation

/// Immutable surface rows available even before the terminal link supplies a graph.
struct CloudMachineSurfacePresentation {
    static func displays(resources: [SurfaceResource], info: SurfaceMachineInfo) -> [SurfaceResource] {
        let displays = resources.filter { $0.kind == .display }
        guard info.hasDesktop else { return [] }
        guard displays.isEmpty else { return displays }
        return [CmuxTuiSnapshotParser.display(
            machine: info.id,
            directURL: info.privateAddress.map { CmuxTuiSurfaceProvider.privateDesktopURL(privateAddress: $0) }
        )]
    }

    static func emptyPorts(info: SurfaceMachineInfo) -> CloudTreeNode {
        let text: String
        let style: CloudTreePlaceholder.Style
        switch info.linkState {
        case .connecting:
            text = String(localized: "cloudTree.ports.loading", defaultValue: "Discovering ports…")
            style = .connecting
        case .error:
            text = info.linkError ?? String(localized: "cloudTree.ports.failed", defaultValue: "Couldn’t discover ports. Refresh to retry.")
            style = .error
        case .asleep:
            text = String(localized: "cloudTree.ports.asleep", defaultValue: "Open the machine to discover ports")
            style = .dimmed
        case .unavailable:
            text = String(localized: "cloudTree.ports.unavailable", defaultValue: "Port discovery unavailable. Refresh to retry.")
            style = .dimmed
        case .connected, .notApplicable:
            text = String(localized: "cloudTree.ports.empty", defaultValue: "No reachable ports")
            style = .dimmed
        }
        return CloudTreeNode(
            id: "machine:\(info.id.rawValue)/ports/status",
            kind: .placeholder(machine: info.id, CloudTreePlaceholder(text: text, style: style))
        )
    }
}
