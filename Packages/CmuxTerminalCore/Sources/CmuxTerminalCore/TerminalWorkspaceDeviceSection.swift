public import Foundation

/// A grouping of terminal workspaces that all belong to the same ``TerminalHost``.
public struct TerminalWorkspaceDeviceSection: Identifiable, Equatable {
    /// The host the section represents.
    public let host: TerminalHost
    /// The workspaces belonging to ``host``, in display order.
    public let workspaces: [TerminalWorkspace]

    /// Creates a device section.
    /// - Parameters:
    ///   - host: The host the section represents.
    ///   - workspaces: The workspaces belonging to the host.
    public init(host: TerminalHost, workspaces: [TerminalWorkspace]) {
        self.host = host
        self.workspaces = workspaces
    }

    /// The section identity (the host identifier).
    public var id: TerminalHost.ID { host.id }

    /// The section title (the host name).
    public var title: String {
        host.name
    }

    /// A secondary line (the hostname) shown when it differs from ``title``.
    public var subtitle: String? {
        let hostname = host.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostname.isEmpty else { return nil }
        guard hostname.caseInsensitiveCompare(host.name) != .orderedSame else { return nil }
        return hostname
    }
}
