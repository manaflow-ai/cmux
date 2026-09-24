import CmuxCloudTui
import CmuxCore
import CmuxSurfaceCatalogModel
import Foundation

/// Hosting metadata for the shared terminal provider. SSH never requires a Cloud account.
enum RemoteTuiMachine: Sendable {
    case cloud(VMSummary)
    case ssh(SSHTuiConnection)

    var machine: SurfaceMachineID {
        switch self {
        case .cloud(let summary): return .cloud(summary.id)
        case .ssh(let connection): return .ssh(connection.identityDigest)
        }
    }

    var id: String { machine.rawValue }
    var cloudSummary: VMSummary? { if case .cloud(let value) = self { return value }; return nil }
    var preferredName: String {
        switch self {
        case .cloud(let summary): return summary.preferredName
        case .ssh(let connection): return connection.configuration.displayTarget
        }
    }
    var status: String { cloudSummary?.status ?? "running" }
    var provider: String { cloudSummary?.provider ?? "ssh" }
    var image: String { cloudSummary?.image ?? "" }
    var resolvedKind: VMMachineKind { cloudSummary?.resolvedKind ?? .base }
    var preferredPrivateAddress: String? { machine.isSSH ? "127.0.0.1" : cloudSummary?.preferredPrivateAddress }
    var capabilities: VMCapabilities {
        cloudSummary?.capabilities ?? VMCapabilities(snapshot: false, restore: false, fork: false, exec: true, stats: false, ports: true, desktop: false, sizing: false, persistentHome: true, attachTransports: ["ssh"])
    }
    var defaultTerminalCommand: [String] {
        switch self {
        case .cloud: return CloudTuiCommandLine.defaultTerminalCommand
        case .ssh(let connection): return connection.shellCommand
        }
    }
}
