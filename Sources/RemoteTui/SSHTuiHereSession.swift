import Bonsplit
import CmuxFoundation
import CmuxSurfaceCatalogModel
import CoreFoundation
import Darwin
import Foundation

/// Owns the local shell parked for one in-place SSH visit. The remote view has
/// its own surface identity, so late attachment callbacks cannot target it.
@MainActor
final class SSHTuiHereSession {
    let operationID: UUID
    let paneID: PaneID
    let originalTransfer: Workspace.DetachedSurfaceTransfer
    let reservation: CloudTerminalPaneReservation
    let localDirectory: String
    let originalTitle: String?
    let originalTitleSource: Workspace.CustomTitleSource
    var requestedTitle: String?
    var connectionTask: Task<Void, Error>?
    private(set) var callerProcessIdentity: AgentPIDProcessIdentity?
    private(set) var callerObservation: AgentRestoreEvidenceSubscription?
    private(set) var callerObservationTask: Task<Void, Never>?

    init(operationID: UUID, paneID: PaneID, originalTransfer: Workspace.DetachedSurfaceTransfer,
         reservation: CloudTerminalPaneReservation, localDirectory: String,
         originalTitle: String?, originalTitleSource: Workspace.CustomTitleSource) {
        self.operationID = operationID
        self.paneID = paneID
        self.originalTransfer = originalTransfer
        self.reservation = reservation
        self.localDirectory = localDirectory
        self.originalTitle = originalTitle
        self.originalTitleSource = originalTitleSource
    }

    /// Decodes an exact process generation without accepting JSON Boolean,
    /// floating-point, truncated or overflowing identities.
    static func callerProcess(from value: Any?) throws -> AgentPIDProcessIdentity {
        guard let fields = value as? [String: Any],
              let pid = integer(fields["pid"]), pid > 0, pid <= Int64(Int32.max),
              let seconds = integer(fields["start_seconds"]), seconds > 0,
              let microseconds = integer(fields["start_microseconds"]),
              microseconds >= 0, microseconds < 1_000_000 else {
            throw callerUnavailableError
        }
        return AgentPIDProcessIdentity(pid: pid_t(pid), startSeconds: seconds, startMicroseconds: microseconds)
    }

    static func requireLiveCaller(_ identity: AgentPIDProcessIdentity) throws {
        guard AgentPIDProcessIdentity(pid: identity.pid) == identity else { throw callerUnavailableError }
    }

    /// The subscription is already resumed before the last liveness read.
    /// Buffered exit evidence closes the check-to-handoff race without polling.
    func observeCallerProcess(
        _ identity: AgentPIDProcessIdentity,
        subscription: AgentRestoreEvidenceSubscription,
        in workspace: Workspace
    ) throws {
        cancelCallerObservation()
        callerObservation = subscription
        do { try Self.requireLiveCaller(identity) }
        catch {
            cancelCallerObservation()
            throw error
        }
        callerProcessIdentity = identity
        callerObservationTask = Task { @MainActor [weak self, weak workspace] in
            for await _ in subscription.events {
                guard !Task.isCancelled else { return }
                // Cancellation merely finishes the stream. Only an actual
                // process exit/reuse may end a visit; socket reconnection does not.
                guard AgentPIDProcessIdentity(pid: identity.pid) != identity else { continue }
                guard let self, let workspace, workspace.sshTuiHereSession === self else { return }
                workspace.finishSSHTuiHereSession(rollback: self.connectionTask != nil)
                return
            }
        }
    }

    func cancelCallerObservation() {
        callerObservationTask?.cancel()
        callerObservationTask = nil
        callerObservation?.cancel()
        callerObservation = nil
        callerProcessIdentity = nil
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)) else {
            return nil
        }
        return Int64(number.stringValue)
    }

    private static var callerUnavailableError: SurfaceCatalogError {
        .unsupported(String(
            localized: "cli.ssh.here.callerUnavailable",
            defaultValue: "ssh --here could not verify the calling process. Run it again from the terminal pane."
        ))
    }
}
