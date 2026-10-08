import CmuxSurfaceCatalogModel
import Foundation

/// Persistent, write-only permission for OSC 52 emitted by an SSH-backed
/// cmux-tui machine.
///
/// The key is the `SSHTuiConnection.identityDigest` carried by
/// ``SurfaceMachineID/ssh``. It includes the destination, port, identity file,
/// and persistent SSH options, so trusting one endpoint cannot silently trust a
/// different host or authentication route that happens to share its display
/// name. Clipboard reads are intentionally never admitted by this store.
@MainActor
final class SSHClipboardWriteTrustStore {
    private static let trustedIdentitiesKey = "terminal.sshClipboardWriteTrustedIdentities"

    private let defaults: UserDefaults
    private var trustedIdentities: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let values = defaults.array(forKey: Self.trustedIdentitiesKey) as? [String] ?? []
        trustedIdentities = Set(values.filter { !$0.isEmpty })
    }

    func isTrusted(_ machine: SurfaceMachineID) -> Bool {
        guard case .ssh(let identity) = machine else { return false }
        return trustedIdentities.contains(identity)
    }

    func setTrusted(_ trusted: Bool, for machine: SurfaceMachineID) {
        guard case .ssh(let identity) = machine, !identity.isEmpty else { return }
        if trusted {
            trustedIdentities.insert(identity)
        } else {
            trustedIdentities.remove(identity)
        }
        defaults.set(trustedIdentities.sorted(), forKey: Self.trustedIdentitiesKey)
    }

    /// Cloud mirrors retain their existing provider grant. SSH mirrors need the
    /// explicit per-machine opt-in. Local and device surfaces remain denied.
    func allowsRemoteClipboardWrites(for machine: SurfaceMachineID) -> Bool {
        if machine.cloudMachineID != nil { return true }
        return machine.isSSH && isTrusted(machine)
    }

    /// OSC 52 trust is write-only. Keep this explicit so future callers cannot
    /// accidentally infer clipboard-read permission from the write grant.
    func allowsRemoteClipboardReads(for machine: SurfaceMachineID) -> Bool {
        _ = machine
        return false
    }
}
