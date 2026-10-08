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
public final class SSHClipboardWriteTrustStore {
    private static let trustedIdentitiesKey = "terminal.sshClipboardWriteTrustedIdentities"

    private let defaults: UserDefaults
    private var trustedIdentities: Set<String>

    /// Loads the grants from the caller-owned persistence domain.
    ///
    /// - Parameter defaults: The app settings domain or an isolated test suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
        let values = defaults.array(forKey: Self.trustedIdentitiesKey) as? [String] ?? []
        trustedIdentities = Set(values.filter { !$0.isEmpty })
    }

    /// Returns whether the exact SSH endpoint has an explicit write grant.
    ///
    /// - Parameter machine: The endpoint identity, including connection options.
    /// - Returns: False for untrusted SSH identities and all non-SSH identities.
    public func isTrusted(_ machine: SurfaceMachineID) -> Bool {
        guard case .ssh(let identity) = machine else { return false }
        return trustedIdentities.contains(identity)
    }

    /// Persists a grant or revocation for one nonempty SSH identity.
    ///
    /// - Parameters:
    ///   - trusted: Whether remote clipboard writes should be allowed.
    ///   - machine: The SSH endpoint; other machine kinds are ignored.
    public func setTrusted(_ trusted: Bool, for machine: SurfaceMachineID) {
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
    ///
    /// - Parameter machine: The source of the remote output.
    /// - Returns: Whether automatic remote clipboard writes are allowed.
    public func allowsRemoteClipboardWrites(for machine: SurfaceMachineID) -> Bool {
        if machine.cloudMachineID != nil { return true }
        return machine.isSSH && isTrusted(machine)
    }

    /// OSC 52 trust is write-only. Keep this explicit so future callers cannot
    /// accidentally infer clipboard-read permission from the write grant.
    ///
    /// - Parameter machine: The source requesting clipboard contents.
    /// - Returns: Always false; native paste intent is handled separately.
    public func allowsRemoteClipboardReads(for machine: SurfaceMachineID) -> Bool {
        _ = machine
        return false
    }
}
