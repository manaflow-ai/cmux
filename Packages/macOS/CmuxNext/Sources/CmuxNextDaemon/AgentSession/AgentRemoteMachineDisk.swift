import Foundation

/// The disk of the machine a chat runs on, read through that machine's own daemon (never this Mac's):
/// its folders for a new chat (`agent-session-folders`) and one folder's listing for the folder chooser
/// (`agent-session-list-dir`, Leo, 2026-11-23: "Own machines as good as Cloud ... a folder chooser").
@MainActor
public struct AgentRemoteMachineDisk {
    private let surface: UInt64
    private let endpoint: AgentSessionAttachClient.EndpointProvider
    private let capabilities: (folders: Bool, listDir: Bool)

    public init(surface: UInt64, endpoint: @escaping AgentSessionAttachClient.EndpointProvider, supports: (String) -> Bool) {
        (self.surface, self.endpoint) = (surface, endpoint)
        capabilities = (supports(DaemonCapability.agentSessionFolders.rawValue), supports(DaemonCapability.agentSessionListDir.rawValue))
    }

    /// That machine's work folder and the folders under it; none when its daemon lacks the verb.
    public func folders() async -> [String] {
        guard capabilities.folders else { return [] }
        let client = AgentSessionAttachClient(surface: surface, endpoint: endpoint)
        defer { Task { await client.close() } }
        return (try? await client.folders().folders) ?? []
    }

    /// One folder of that machine (`path` nil: its work folder, else home): the daemon's listing, else
    /// `error` {code, message} for the chooser to say, never a throw.
    public func list(_ path: String?, files: Bool) async -> [String: Any] {
        guard capabilities.listDir else { return Self.failure("list_dir.unsupported", "This machine's cmux is too old to list its folders; update it, or type the path") }
        let client = AgentSessionAttachClient(surface: surface, endpoint: endpoint)
        defer { Task { await client.close() } }
        do {
            guard let data = try await client.listDirectory(path, files: files), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return Self.failure("list_dir.unsupported", "This machine's cmux is too old to list its folders; update it, or type the path")
            }
            return object
        } catch { return Self.failure("list_dir.unreachable", "This machine did not answer; check that it is online, or type the path") }
    }

    /// What the chooser shows when no machine can answer.
    public static let unavailable = failure("list_dir.unavailable", "This machine is not connected yet")

    private static func failure(_ code: String, _ message: String) -> [String: Any] { ["error": ["code": code, "message": message]] }
}
