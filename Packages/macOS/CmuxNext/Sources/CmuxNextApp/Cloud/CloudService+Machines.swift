import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextDaemon
import Foundation

// A machine's mutations after its create, and the account's sign-out, install and link (moved out of
// CloudService.swift whole).
extension CloudService {
    func deleteMachine(_ machineID: String) async throws {
        try await api.deleteMachine(machineID)
        // A list in flight was asked while this machine still existed.
        listGeneration += 1
        creations.machineRemoved(machineID)
        machines.remove(machineID)?.disconnect()
        logger.info("deleted machine \(machineID, privacy: .public)")
    }

    func pauseMachine(_ machineID: String) async throws {
        try await api.pauseMachine(machineID)
        await refresh()
        logger.info("paused machine \(machineID, privacy: .public)")
    }

    func resumeMachine(_ machineID: String) async throws {
        try await api.resumeMachine(machineID)
        await refresh()
        logger.info("resumed machine \(machineID, privacy: .public)")
    }

    /// The machine's idle auto-pause (`PUT /api/vm/{id}/idle-pause`): minutes
    /// of idle before cmux Cloud pauses it; 0 is Off.
    func setIdlePause(_ machineID: String, minutes: Int) async throws {
        try await api.setIdlePause(machineID, minutes: minutes)
        machines.session(machineID)?.machine.idlePauseMinutes = minutes
        logger.info("set idle pause \(machineID, privacy: .public) to \(minutes) min")
    }

    func renameMachine(_ machineID: String, to name: String) async throws {
        try await api.renameMachine(machineID, to: name.isEmpty ? nil : name)
        machines.session(machineID)?.machine.displayName = name.isEmpty ? nil : name
    }

    func signOut() async {
        for hook in willSignOut { hook() }
        AgentPaneTailCache.shared.clear() // the panes' chat tails: memory only, forgotten whole
        // No ensure starts from here until the session's final endLink (the
        // signed-out branch above, after auth.signOut).
        link.beginEnding()
        dropAllMachines()
        await link.endLink(final: false)
        if let hub { await hub.revoke() }
        // Revoke the install while the Stack session still exists.
        if let stackUser = auth.user?.id {
            let auth = auth
            await installIdentity.signOut(stackUser: stackUser, session: { try await auth.tokens().access })
        }
        // An ensure that slipped in during the revoke: stop that link too.
        await link.stopLink()
        await auth.signOut()
    }

    /// Starts this Mac's `cmux link` (``CloudLinkLifecycle/ensureLink()``).
    func ensureLink() async { await link.ensureLink() }

    /// ``CloudLinkLifecycle/ensureLinkReport()``, for the DEBUG socket method.
    func ensureLinkReport() async -> JSONValue { await link.ensureLinkReport() }

    /// Registers (or reuses) this Mac's install for the signed-in user and
    /// mints one token. A failure is logged: the relay mints again when it
    /// needs a token, and the hub path does not depend on it.
    func installSignedIn() async {
        guard let stackUser = auth.user?.id, mayCallCloud else { return }
        let auth = auth
        do {
            try await installIdentity.signedIn(stackUser: stackUser, session: { try await auth.tokens().access })
            hostReplica.installReady()
        } catch {
            logger.error("install registration failed: \(String(describing: error), privacy: .public)")
        }
    }
}
