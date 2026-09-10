import Foundation

/// The cmux-tui provider is the one machine kind that knows its workspaces' geometry.
extension CmuxTuiSurfaceProvider: SurfaceProjectionLayoutProviding {
    /// One `session current snapshot` read over the machine's link, translated into the
    /// tree `vm.workspace_open` and the sidebar's Open Workspace reproduce locally.
    /// Deliberately not cached: the person is opening the workspace right now, so the
    /// daemon's current screen is the only correct answer, and the same read is what
    /// every other provider verb starts from.
    func projectionLayout(workspaceID: String) async throws -> SurfaceProjectionLayout? {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        let data = try await link.run(arguments: CloudTuiCommandLine.snapshotArguments(socketPath: connected.socketPath))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              CmuxTuiSnapshotParser.state(fromSnapshot: object, machine: machine) != nil else {
            throw ProviderError.invalidSnapshot(machineID)
        }
        return CloudWorkspaceLayoutTranslator.projectionLayout(
            snapshot: object,
            machine: machine,
            workspaceID: workspaceID,
            resources: catalog.snapshot.resources(on: machine)
        )
    }
}
