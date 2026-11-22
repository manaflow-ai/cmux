import Foundation

/// What one cmux-tui daemon can do for this app, from its `identify` (or
/// from the handshake that refused it). Every machine reports its own:
/// the local daemon runs the bundled build, a Cloud machine the build its
/// image baked or its last in-place upgrade installed
/// (docs/cloud-guest-upgrades.md). Features follow the capabilities, never
/// the version string.
public struct DaemonCompatibility: Sendable, Equatable {
    public enum Level: String, Sendable {
        /// Every capability the app uses.
        case current
        /// Connects; the features behind `missingOptional` are off.
        case limited
        /// The handshake refused the daemon; nothing works until it is updated.
        case incompatible
    }

    public var level: Level
    /// `identify.version`; empty when the handshake refused the daemon before
    /// the app could read it.
    public var version: String
    public var buildCommit: String?
    /// The session's stable UUID (`DaemonIdentity.sessionID`) and name; nil
    /// when the handshake refused the daemon.
    public var sessionID: String?
    public var sessionName: String?
    /// `identify.protocol`; nil when the handshake refused the daemon.
    public var protocolVersion: Int?
    /// Why the handshake refused the daemon (capabilities, or a protocol or
    /// app description).
    public var missingRequired: [String]
    /// Optional capabilities the app would use (`DaemonCapabilities.shared.optional`
    /// order) that this daemon lacks.
    public var missingOptional: [String]

    /// `notNeeded` names optional capabilities this app does not use on
    /// this daemon (home-only state on a remote machine), so their absence
    /// does not make it limited.
    public init(identity: DaemonIdentity, notNeeded: Set<String> = []) {
        version = identity.version
        buildCommit = identity.buildCommit
        sessionID = identity.sessionID
        sessionName = identity.session.isEmpty ? nil : identity.session
        protocolVersion = identity.protocolVersion
        missingRequired = DaemonCapabilities.shared.required.filter { !identity.supports($0) }
        missingOptional = DaemonCapabilities.shared.optional.filter { !notNeeded.contains($0) && !identity.supports($0) }
        level = !missingRequired.isEmpty ? .incompatible : missingOptional.isEmpty ? .current : .limited
    }

    /// The compatibility a refused handshake shows, or nil when `refusal`
    /// says nothing about the daemon's build (a timeout, a closed socket).
    public init?(refusal: DaemonError) {
        switch refusal {
        case .missingCapabilities(let names): missingRequired = names
        case .unsupportedProtocol(let version): missingRequired = ["protocol \(version) (need 12)"]
        case .wrongApp(let app): missingRequired = ["app \(app) (need cmux-tui)"]
        default: return nil
        }
        level = .incompatible
        version = ""
        missingOptional = []
    }

    /// `0.1.0 (3412812eae76)`: the version and a 12-character commit.
    public var versionLabel: String {
        guard let buildCommit, !buildCommit.isEmpty else { return version }
        let short = String(buildCommit.prefix(12))
        return version.isEmpty ? short : "\(version) (\(short))"
    }
}
