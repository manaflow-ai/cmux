public import Foundation

/// One workspace eligible for import into cmux-next.
public nonisolated struct ClassicSessionWorkspace: Codable, Equatable, Sendable {
    public let name: String
    public let workingDirectory: String
    public let layout: ClassicSessionLayout
    /// The SSH host its terminals ran on; nil for a local workspace.
    public let remote: ClassicSessionRemote?
    /// The Cloud VM it ran on; nil unless it was a Cloud VM workspace.
    public let cloudVM: String?

    public init(name: String, workingDirectory: String, layout: ClassicSessionLayout,
                remote: ClassicSessionRemote? = nil, cloudVM: String? = nil) {
        self.name = name
        self.workingDirectory = workingDirectory
        self.layout = layout
        self.remote = remote
        self.cloudVM = cloudVM
    }

    /// This workspace with each folder that `exists` rejects replaced by
    /// `home`: a terminal cannot start in a folder that is gone.
    public func openingMissingFolders(in home: String, exists: (String) -> Bool) -> ClassicSessionWorkspace {
        let folder = { (path: String) in exists(path) ? path : home }
        return ClassicSessionWorkspace(name: name, workingDirectory: folder(workingDirectory),
                                       layout: layout.mappingFolders(folder), remote: remote, cloudVM: cloudVM)
    }
}

/// Where a classic SSH workspace ran (`remote`): `user@host` and its port.
public nonisolated struct ClassicSessionRemote: Codable, Equatable, Sendable {
    public let destination: String
    public let port: Int?

    public init(destination: String, port: Int?) {
        self.destination = destination
        self.port = port
    }

    /// `[user@]host[:port]`, an IPv6 host in brackets. Port 22 is left out,
    /// so it names the same machine as a saved entry without a port.
    public var sshDestination: String {
        let at = destination.lastIndex(of: "@")
        let user = at.map { String(destination[...$0]) } ?? ""
        var host = at.map { String(destination[destination.index(after: $0)...]) } ?? destination
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        guard let port, port != 22 else { return user + host }
        return "\(user)\(host):\(port)"
    }
}

