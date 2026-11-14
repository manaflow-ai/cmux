import CmuxDeviceHub
import CmuxRemoteWire
import Foundation

/// The host's durable lease and its exact worker Keychain namespace. Disk and Keychain I/O stay off MainActor.
actor RemoteCaptureLease {
    let stateDirectory: String
    let keychainScope: String
    let home: String
    let empty: @Sendable () throws -> Bool
    let remove: @Sendable () throws -> DeviceCaptureNamespace.Removal

    init(stateDirectory: String, keychainScope: String, home: String,
         empty: @escaping @Sendable () throws -> Bool,
         remove: @escaping @Sendable () throws -> DeviceCaptureNamespace.Removal) {
        self.stateDirectory = stateDirectory; self.keychainScope = keychainScope; self.home = home
        self.empty = empty; self.remove = remove
    }

    func prepare(_ binding: CaptureLeaseBinding, children: RemoteChildLifetime, workerAbsent: Bool,
                 timeout: Duration = .seconds(15)) async -> CaptureLeaseResult {
        guard binding.owns(stateDirectory: stateDirectory, home: home), workerAbsent else {
            return CaptureLeaseResult(code: "remote_not_pristine")
        }
        // The startup permission probe is a tracked child, not an identity writer.
        // Let it reap before the atomic claim; a competing late spawn still fails closed.
        guard await children.waitUntilEmpty(timeout: timeout) else {
            return CaptureLeaseResult(code: "remote_prepare_timeout")
        }
        var claimed = false
        do {
            try CaptureLeaseMarker.transaction(stateDirectory: stateDirectory) { stored in
                if let existing = stored {
                    guard existing.binding == binding, existing.keychainScope == keychainScope,
                          !existing.workerStarted, !existing.cleaning else { throw CocoaError(.fileWriteNoPermission) }
                }
                guard children.claimIdle() else { throw CocoaError(.fileWriteNoPermission) }
                claimed = true
                guard try empty() else { throw CocoaError(.fileWriteFileExists) }
                // Claim only an already-empty namespace. Prepare never calls remove().
                stored = CaptureLeaseMarker(binding: binding, keychainScope: keychainScope)
            }
            // The app must observe this pristine host exit before relaunching with credentials.
            // Only a fresh host may spawn against the still-active durable marker.
            children.freeze()
            return CaptureLeaseResult(code: "no_remote_started", leaseBound: true, verifiedAbsent: true, quiescent: true)
        } catch {
            if claimed { children.reopenAfterPrepare() }
            return CaptureLeaseResult(code: "remote_prepare_unverified")
        }
    }

    /// Persist the restart barrier before the caller freezes or signals workers.
    /// A wrong lease has no effects, and a failed drain retains this terminal phase.
    func beginCleanup(_ binding: CaptureLeaseBinding) -> Bool {
        guard binding.owns(stateDirectory: stateDirectory, home: home) else { return false }
        do {
            try CaptureLeaseMarker.transaction(stateDirectory: stateDirectory) { stored in
                guard var marker = stored, marker.binding == binding,
                      marker.keychainScope == keychainScope else { throw CocoaError(.fileWriteNoPermission) }
                marker.cleaning = true
                stored = marker
            }
            return true
        } catch { return false }
    }

    func cleanup(_ binding: CaptureLeaseBinding, writersExited: Bool) -> CaptureLeaseResult {
        guard binding.owns(stateDirectory: stateDirectory, home: home),
              let marker = try? CaptureLeaseMarker.read(stateDirectory: stateDirectory),
              marker.binding == binding, marker.keychainScope == keychainScope, marker.cleaning else {
            return CaptureLeaseResult(code: "remote_lease_mismatch")
        }
        guard writersExited else { return CaptureLeaseResult(code: "remote_worker_timeout", leaseBound: true) }
        do {
            let removed = try remove()
            guard try empty() else { return CaptureLeaseResult(code: "remote_namespace_not_empty", leaseBound: true) }
            // Keep the marker until the app proves host exit and its raw-bundle relay namespace is absent.
            return CaptureLeaseResult(code: "remote_exit_unverified", leaseBound: true, workerStarted: marker.workerStarted,
                                      identities: removed.identities, relays: removed.relays, verifiedAbsent: true, quiescent: true)
        } catch { return CaptureLeaseResult(code: "remote_cleanup_unverified", leaseBound: true) }
    }
}
