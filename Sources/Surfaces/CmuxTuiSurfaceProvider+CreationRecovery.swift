import Foundation
import os

private let cloudTerminalCreationLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "CloudTerminalCreation"
)

@MainActor
extension CmuxTuiSurfaceProvider {
    /// Runs one correlated Cloud terminal creation and records only its durable
    /// CreatedPath. Ambiguous replies are reconciled before any retry.
    func createTerminalWithRecovery(
        command: [String]?,
        cwd: String?,
        name: String?,
        remoteWorkspaceID: String?,
        onExit: String?
    ) async throws -> SurfaceResource {
        let intentID = UUID().uuidString.lowercased()
        let correlationKey = "cmux-cloud-terminal-\(intentID)"
        cloudTerminalCreationLogger.info(
            "create machine=\(self.machineID, privacy: .public) correlation=\(correlationKey, privacy: .private(mask: .hash)) phase=intent"
        )
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else {
            throw ProviderError.machineAsleep(machineID)
        }
        let requestedWorkspace = remoteWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceID = requestedWorkspace.flatMap { $0.isEmpty ? nil : $0 } ?? "current"
        let argv = CloudTuiCommandLine.commandStartingIn(
            cwd: cwd,
            command: (command?.isEmpty == false ? command : nil) ?? CloudTuiCommandLine.defaultTerminalCommand
        )
        let idempotencyKey = "cmux-cloud-terminal-attempt-\(intentID)"
        let coordinator = CloudTuiCreationCoordinator(
            commandRunner: link,
            socketPath: connected.socketPath,
            workspaceID: workspaceID,
            command: argv,
            onExit: onExit,
            correlationKey: correlationKey,
            idempotencyKey: idempotencyKey,
            clock: attachmentClock
        )

        cloudTerminalCreationLogger.info(
            "create machine=\(self.machineID, privacy: .public) correlation=\(correlationKey, privacy: .private(mask: .hash)) phase=link-ready"
        )
        do {
            let created = try await coordinator.run()
            let resolvedWorkspaceID = await resolvedWorkspaceID(
                for: created,
                requestedWorkspace: workspaceID
            )
            cloudTerminalCreationLogger.info(
                "create machine=\(self.machineID, privacy: .public) correlation=\(correlationKey, privacy: .private(mask: .hash)) phase=acknowledged terminal=\(created.terminalID, privacy: .private(mask: .hash)) generation=\((created.cursor?.generation ?? "unavailable"), privacy: .private(mask: .hash)) revision=\((created.cursor?.revision).map(String.init) ?? "unavailable", privacy: .public)"
            )
            return recordCreatedTerminal(created, workspaceID: resolvedWorkspaceID, name: name, cwd: cwd)
        } catch CloudTuiCreationCoordinator.Failure.unsupported {
            throw ProviderError.terminalCreationUnsupported(correlationKey)
        } catch CloudTuiCreationCoordinator.Failure.outcomeUnknown {
            throw ProviderError.terminalCreationOutcomeUnknown(correlationKey)
        }
    }

    private func resolvedWorkspaceID(
        for created: CmuxTuiSnapshotParser.CreatedTerminalPath,
        requestedWorkspace: String
    ) async -> String? {
        if let workspaceID = created.workspaceID, !workspaceID.isEmpty { return workspaceID }
        guard requestedWorkspace == "current" else { return requestedWorkspace }
        _ = await refreshCurrentGraph(force: true)
        guard let state = cloudState else { return nil }
        for tab in state.lookupIndex.tabs(contentKind: "terminal", contentID: created.terminalID) {
            guard let pane = state.lookupIndex.pane(id: tab.paneID),
                  let screen = state.lookupIndex.screen(id: pane.screenID) else { continue }
            return screen.workspaceID
        }
        return nil
    }
}
