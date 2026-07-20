public import Foundation

/// Multiplexes every terminal in a workspace over one renderer process.
public actor RendererWorkspaceMirrorService {
    public enum Error: Swift.Error {
        case workspaceUnavailable(UUID)
    }

    private struct SurfaceRecord {
        var configuration: RendererSurfaceConfiguration
        let mirror: RendererSurfaceMirror
    }

    private struct WorkspaceRecord {
        var generation: UInt64
        var connection: RendererWorkspaceConnection
        var surfaces: [UUID: SurfaceRecord]
        var eventTask: Task<Void, Never>?
    }

    private let pool: RendererWorkerProcessPool
    private var workspaces: [UUID: WorkspaceRecord] = [:]
    private var startingWorkspaces: [UUID: Task<RendererWorkspaceConnection, any Swift.Error>] = [:]
    private var latestGeneration: [UUID: UInt64] = [:]

    public init(helperURL: URL) {
        pool = RendererWorkerProcessPool(helperURL: helperURL)
    }

    /// Creates the app-side queue synchronously, before worker startup. Input,
    /// geometry, and configuration messages can therefore accumulate from the
    /// moment the local Ghostty surface becomes interactive.
    public nonisolated func makeMirror(
        configuration: RendererSurfaceConfiguration,
        outputRelay: RendererProcessOutputRelay
    ) -> RendererSurfaceMirror {
        RendererSurfaceMirror(configuration: configuration, outputRelay: outputRelay)
    }

    public func register(
        configuration: RendererSurfaceConfiguration,
        mirror: RendererSurfaceMirror
    ) async throws {
        let workspaceID = configuration.identity.workspaceID

        if var workspace = workspaces[workspaceID] {
            let identity = RendererSurfaceIdentity(
                workspaceID: workspaceID,
                surfaceID: configuration.identity.surfaceID,
                generation: workspace.generation
            )
            let currentConfiguration = mirror.configuration(
                basedOn: configuration,
                identity: identity
            )
            workspace.surfaces[identity.surfaceID] = SurfaceRecord(
                configuration: currentConfiguration,
                mirror: mirror
            )
            workspaces[workspaceID] = workspace
            await workspace.connection.send(try RendererIPCCommand.createSurface(currentConfiguration))
            mirror.attach(connection: workspace.connection, identity: identity)
            return
        }

        let generation: UInt64
        let startTask: Task<RendererWorkspaceConnection, any Swift.Error>
        if let existing = startingWorkspaces[workspaceID] {
            startTask = existing
            generation = latestGeneration[workspaceID] ?? 1
        } else {
            generation = (latestGeneration[workspaceID] ?? 0) &+ 1
            latestGeneration[workspaceID] = generation
            let pool = pool
            startTask = Task {
                try await pool.start(workspaceID: workspaceID, generation: generation)
            }
            startingWorkspaces[workspaceID] = startTask
        }
        let connection: RendererWorkspaceConnection
        do {
            connection = try await startTask.value
        } catch {
            startingWorkspaces.removeValue(forKey: workspaceID)
            mirror.finish()
            throw error
        }
        startingWorkspaces.removeValue(forKey: workspaceID)

        // Another registration awaiting the same start task may have installed
        // the workspace record first. Reuse its connection and add this surface.
        if var workspace = workspaces[workspaceID] {
            let identity = RendererSurfaceIdentity(
                workspaceID: workspaceID,
                surfaceID: configuration.identity.surfaceID,
                generation: workspace.generation
            )
            let currentConfiguration = mirror.configuration(
                basedOn: configuration,
                identity: identity
            )
            workspace.surfaces[identity.surfaceID] = SurfaceRecord(
                configuration: currentConfiguration,
                mirror: mirror
            )
            workspaces[workspaceID] = workspace
            await workspace.connection.send(try RendererIPCCommand.createSurface(currentConfiguration))
            mirror.attach(connection: workspace.connection, identity: identity)
            return
        }
        let identity = RendererSurfaceIdentity(
            workspaceID: workspaceID,
            surfaceID: configuration.identity.surfaceID,
            generation: generation
        )
        let currentConfiguration = mirror.configuration(
            basedOn: configuration,
            identity: identity
        )
        var workspace = WorkspaceRecord(
            generation: generation,
            connection: connection,
            surfaces: [identity.surfaceID: SurfaceRecord(
                configuration: currentConfiguration,
                mirror: mirror
            )],
            eventTask: nil
        )
        workspace.eventTask = Task { [weak self, events = connection.events] in
            for await event in events {
                await self?.route(event, workspaceID: workspaceID, generation: generation)
            }
            await self?.workerEnded(workspaceID: workspaceID, generation: generation)
        }
        workspaces[workspaceID] = workspace
        await connection.send(try RendererIPCCommand.createSurface(currentConfiguration))
        mirror.attach(connection: connection, identity: identity)
    }

    public func unregister(_ mirror: RendererSurfaceMirror) async {
        let identity = mirror.identity
        guard var workspace = workspaces[identity.workspaceID],
              workspace.surfaces.removeValue(forKey: identity.surfaceID) != nil else {
            mirror.finish()
            return
        }
        await workspace.connection.send(RendererXPCObject(
            RendererIPCCommand.surface(operation: .destroySurface, identity: identity)
        ))
        mirror.detach(identity: identity)
        mirror.finish()
        if workspace.surfaces.isEmpty {
            workspace.eventTask?.cancel()
            workspaces.removeValue(forKey: identity.workspaceID)
            await pool.stop(workspaceID: identity.workspaceID)
        } else {
            workspaces[identity.workspaceID] = workspace
        }
    }

    private func route(
        _ event: RendererXPCObject,
        workspaceID: UUID,
        generation: UInt64
    ) {
        guard let workspace = workspaces[workspaceID], workspace.generation == generation,
              let surfaceID = RendererIPCMessage.uuid(
                forKey: RendererIPCKey.surfaceID,
                in: event.value
              ), let surface = workspace.surfaces[surfaceID] else { return }
        surface.mirror.yield(event)
    }

    /// A worker cannot reconstruct exact parser state from a bounded byte tail.
    /// Fail open to the intact local renderer instead of presenting a partial
    /// replacement frame. A later surface registration may start a fresh worker.
    private func workerEnded(workspaceID: UUID, generation: UInt64) async {
        guard let current = workspaces[workspaceID],
              current.generation == generation,
              let workspace = workspaces.removeValue(forKey: workspaceID) else {
            return
        }
        for record in workspace.surfaces.values {
            record.mirror.yield(RendererXPCObject(RendererIPCCommand.surface(
                operation: .processExited,
                identity: record.configuration.identity
            )))
            record.mirror.finish()
        }
        await pool.stop(workspaceID: workspaceID)
    }
}
