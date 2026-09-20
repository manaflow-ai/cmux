import Foundation

/// Immutable surface rows available even before the terminal link supplies a graph.
struct CloudMachineSurfacePresentation {
    static func displays(resources: [SurfaceResource], info: SurfaceMachineInfo) -> [SurfaceResource] {
        let displays = resources.filter { $0.kind == .display }
        // Catalogued displays are authoritative even when older machine metadata
        // does not advertise the desktop capability. Preserve every real VNC
        // screen discovered by the daemon during reconnect.
        guard displays.isEmpty else { return displays }
        guard info.hasDesktop else { return [] }
        return [CmuxTuiSnapshotParser.display(
            machine: info.id,
            directURL: info.privateAddress.map { CmuxTuiSurfaceProvider.privateDesktopURL(privateAddress: $0) }
        )]
    }

    static func emptyDisplays(info: SurfaceMachineInfo) -> CloudTreeNode {
        let text: String
        let style: CloudTreePlaceholder.Style
        switch info.linkState {
        case .connecting:
            text = String(localized: "cloudTree.displays.loading", defaultValue: "Discovering displays…")
            style = .connecting
        case .error:
            text = info.linkError ?? String(localized: "cloudTree.displays.failed", defaultValue: "Couldn’t discover displays. Refresh to retry.")
            style = .error
        case .asleep:
            text = String(localized: "cloudTree.displays.asleep", defaultValue: "Displays unavailable while the machine sleeps")
            style = .dimmed
        case .unavailable:
            text = String(localized: "cloudTree.displays.unavailable", defaultValue: "Display discovery unavailable. Refresh to retry.")
            style = .dimmed
        case .connected, .notApplicable:
            text = String(localized: "cloudTree.displays.empty", defaultValue: "No displays available")
            style = .dimmed
        }
        return CloudTreeNode(
            id: "machine:\(info.id.rawValue)/displays/placeholder",
            kind: .placeholder(machine: info.id, CloudTreePlaceholder(text: text, style: style))
        )
    }

    static func emptyPorts(info: SurfaceMachineInfo) -> CloudTreeNode {
        let presentation = CloudPortsStatusPresentation.make(info: info)
        let style: CloudTreePlaceholder.Style = {
            switch info.portDiscoveryState {
            case .loading:
                return .connecting
            case .notRequested:
                switch info.linkState {
                case .connecting: return .connecting
                case .error: return .error
                default: return .dimmed
                }
            case .unavailable, .stale:
                return .error
            case .empty, .unsupported, .available:
                return .dimmed
            }
        }()
        return CloudTreeNode(
            id: "machine:\(info.id.rawValue)/ports/status",
            kind: .placeholder(machine: info.id, CloudTreePlaceholder(
                text: presentation.title,
                style: style,
                opensMachine: info.linkState == .asleep || presentation.action == .openMachine,
                portStatus: presentation
            ))
        )
    }

    static func portStatus(info: SurfaceMachineInfo) -> CloudTreeNode? {
        guard info.portDiscoveryState.keepsStatusAlongsideRows else { return nil }
        let presentation = CloudPortsStatusPresentation.make(info: info)
        return CloudTreeNode(
            id: "machine:\(info.id.rawValue)/ports/status",
            kind: .placeholder(machine: info.id, CloudTreePlaceholder(
                text: presentation.title,
                style: .error,
                portStatus: presentation
            ))
        )
    }
}
