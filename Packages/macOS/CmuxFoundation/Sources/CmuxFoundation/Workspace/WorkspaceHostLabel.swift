import Foundation

/// Where a workspace runs, derived from its connection rather than from the
/// title the user typed.
///
/// Surfaces that label or group workspaces by host (window titles, the Task
/// Manager) share this one value so they agree.
///
/// - SSH: built from the `cmux ssh` destination. The label is the host part
///   with the user and port removed (`leo@big-red:2222` shows as `big-red`).
///   An ssh_config alias stays as typed; cmux never resolves it to its
///   `HostName`, because the alias is the name the user knows the host by.
/// - Cloud: built from the Cloud machine. The label is the machine's name,
///   or its id when the name is unknown.
/// - Local: this Mac. It has no label; surfaces show nothing extra.
public struct WorkspaceHostLabel: Hashable, Sendable {
    /// The kind of host a workspace runs on.
    public enum Kind: String, Hashable, Sendable {
        case local
        case ssh
        case cloud
    }

    /// The kind of host.
    public let kind: Kind
    /// Short display label (`big-red`, `my-vm`). Empty for local workspaces.
    public let label: String
    /// Full identity for tooltips and accessibility (`leo@big-red:2222`,
    /// `my-vm (vm_123)`). Empty for local workspaces.
    public let detail: String
    /// Stable, case-insensitive key for grouping workspaces that share a host:
    /// `local`, `ssh:<host>[:<port>]` (user ignored) or `cloud:<machine id>`.
    public let groupingKey: String

    /// This Mac.
    public static let local = WorkspaceHostLabel(kind: .local, label: "", detail: "", groupingKey: "local")

    /// True for SSH and Cloud workspaces.
    public var isRemote: Bool { kind != .local }

    private init(kind: Kind, label: String, detail: String, groupingKey: String) {
        self.kind = kind
        self.label = label
        self.detail = detail
        self.groupingKey = groupingKey
    }

    /// Label for an SSH workspace.
    ///
    /// - Parameters:
    ///   - destination: The SSH destination: `host`, `user@host`, `user@[::1]`
    ///     or `ssh://user@host:port`.
    ///   - port: The explicitly configured port, if any. It wins over a port in
    ///     an `ssh://` URI, matching `ssh -p`.
    /// - Returns: `nil` when the destination has no host.
    public static func ssh(destination: String, port: Int? = nil) -> WorkspaceHostLabel? {
        guard let parsed = SSHDestination(destination) else { return nil }
        let effectivePort = port ?? parsed.port
        // Only IPv6 literals (two or more colons) need brackets before a port.
        let isIPv6 = parsed.host.filter { $0 == ":" }.count >= 2
        let bracketedHost = isIPv6 ? "[\(parsed.host)]" : parsed.host
        var detail = parsed.user.map { "\($0)@\(bracketedHost)" } ?? bracketedHost
        var key = "ssh:" + bracketedHost.lowercased()
        if let effectivePort {
            detail += ":\(effectivePort)"
            key += ":\(effectivePort)"
        }
        return WorkspaceHostLabel(kind: .ssh, label: parsed.host, detail: detail, groupingKey: key)
    }

    /// Label for a Cloud machine workspace.
    ///
    /// - Parameters:
    ///   - machineID: The Cloud machine id.
    ///   - machineName: The machine's display name, when known.
    /// - Returns: `nil` when the id is empty.
    public static func cloud(machineID: String, machineName: String?) -> WorkspaceHostLabel? {
        let id = machineID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        let name = machineName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let label = name.isEmpty ? id : name
        let detail = label == id ? id : "\(label) (\(id))"
        return WorkspaceHostLabel(kind: .cloud, label: label, detail: detail, groupingKey: "cloud:" + id.lowercased())
    }

    /// Appends the host label to a window title (`title · host`), unless the
    /// workspace is local or the title already names the host.
    ///
    /// - Parameter title: The workspace's display title.
    /// - Returns: The title to show in window chrome.
    public func windowTitle(appendingTo title: String) -> String {
        guard isRemote, !label.isEmpty else { return title }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return label }
        if Self.title(trimmed, namesHost: label) { return trimmed }
        return "\(trimmed) · \(label)"
    }

    /// Whether `title` already contains `host` as a whole word, so
    /// `cmux ssh big-red --name "build @big-red"` does not become
    /// `build @big-red · big-red`.
    static func title(_ title: String, namesHost host: String) -> Bool {
        var searchRange = title.startIndex..<title.endIndex
        while let match = title.range(of: host, options: [.caseInsensitive], range: searchRange) {
            let beforeIsBoundary = match.lowerBound == title.startIndex
                || !isHostCharacter(title[title.index(before: match.lowerBound)])
            let afterIsBoundary = match.upperBound == title.endIndex
                || !isHostCharacter(title[match.upperBound])
            if beforeIsBoundary && afterIsBoundary { return true }
            searchRange = match.upperBound..<title.endIndex
        }
        return false
    }

    private static func isHostCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
    }
}
