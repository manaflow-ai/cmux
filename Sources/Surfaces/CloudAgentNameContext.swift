import Foundation

/// A callback's read precondition, captured before an agent computes its title.
/// Names never identify a resource: the full projection and daemon generation do.
struct CloudAgentNameContext: Hashable, Codable, Sendable {
    let projection: SurfaceProjection
    let generation: String
    let nameRevision: UInt64

    init?(projection: SurfaceProjection, state: CloudVMState) {
        guard let tabID = projection.remoteTabID,
              let tab = state.lookupIndex.tab(id: tabID),
              tab.contentKind == "terminal", tab.contentID == projection.resource.key,
              let pane = state.lookupIndex.pane(id: tab.paneID),
              let screen = state.lookupIndex.screen(id: pane.screenID),
              screen.workspaceID == projection.remoteWorkspaceID,
              let authority = tab.nameAuthority,
              tab.name == nil || authority.source == .auto,
              let cursor = state.cursor else { return nil }
        self.projection = projection
        generation = cursor.generation
        nameRevision = authority.revision
    }

    init?(wire: Any?) {
        guard let wire, JSONSerialization.isValidJSONObject(wire),
              let bytes = try? JSONSerialization.data(withJSONObject: wire),
              let value = try? JSONDecoder().decode(Self.self, from: bytes) else { return nil }
        self = value
    }

    var wire: [String: Any]? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Preserve this callback's identity and revision when encoding the daemon command.
    func renameArguments(socketPath: String, name: String) -> [String] {
        CloudTuiCommandLine.renameTabArguments(
            socketPath: socketPath, tabID: projection.remoteTabID ?? "", name: name
        ) + ["--workspace", projection.remoteWorkspaceID ?? "",
             "--source", "auto", "--expected-generation", generation,
             "--expected-name-revision", String(nameRevision)]
    }
}
