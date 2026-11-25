// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// One process instance: a pid plus its start time, so a reused pid never
/// matches an earlier process.
public struct ProcessStamp: Hashable, Sendable, Codable {
    public var pid: pid_t
    public var startSeconds: UInt64
    public var startMicroseconds: UInt64

    public init(pid: pid_t, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }
}

/// What the kernel says about a connected peer (see `PeerInspector`).
public struct PeerFacts: Sendable, Equatable {
    public var uid: uid_t
    public var stamp: ProcessStamp
    /// The peer's code signature is valid for the running process (audit token).
    public var signatureValid: Bool
    /// The running code's cdhash (nil when unsigned or unreadable).
    public var cdhash: Data?
    /// The peer satisfies the configured release requirement (Developer ID acpmux).
    public var satisfiesRequirement: Bool
    /// Parent chain, nearest first, up to (not including) launchd.
    public var ancestors: [ProcessStamp]

    public init(uid: uid_t, stamp: ProcessStamp, signatureValid: Bool, cdhash: Data?,
                satisfiesRequirement: Bool, ancestors: [ProcessStamp]) {
        self.uid = uid
        self.stamp = stamp
        self.signatureValid = signatureValid
        self.cdhash = cdhash
        self.satisfiesRequirement = satisfiesRequirement
        self.ancestors = ancestors
    }
}

/// Who may use the helper socket. The host sends it over the control pipe.
public struct AdmissionConfig: Sendable, Equatable {
    public var helperUID: uid_t
    /// cdhashes of the acpmux binaries the host trusts (DEV builds: ad-hoc signed).
    public var acpmuxCDHashes: Set<Data>
    /// A code requirement for release acpmux (Developer ID); nil in DEV builds.
    public var acpmuxRequirement: String?
    /// The acpmux daemons the host found (pid + start time); a peer must descend from one.
    public var acpmuxDaemons: Set<ProcessStamp>
    /// The per-launch secret a peer presents first.
    public var secret: Data

    public init(helperUID: uid_t, acpmuxCDHashes: Set<Data>, acpmuxRequirement: String?,
                acpmuxDaemons: Set<ProcessStamp>, secret: Data) {
        self.helperUID = helperUID
        self.acpmuxCDHashes = acpmuxCDHashes
        self.acpmuxRequirement = acpmuxRequirement
        self.acpmuxDaemons = acpmuxDaemons
        self.secret = secret
    }
}

public enum AdmissionRefusal: String, Sendable, Equatable {
    case notConfigured = "not_configured"
    case foreignUser = "foreign_user"
    case invalidSignature = "invalid_signature"
    case unknownCode = "unknown_code"
    case outsideAcpmuxTree = "outside_acpmux_tree"
    case missingSecret = "missing_secret"
    case wrongSecret = "wrong_secret"
}

/// The admission rule. Every check must pass, in this order:
/// 1. the peer runs as this user;
/// 2. its code signature is valid for the running process;
/// 3. its code is acpmux (a host-trusted cdhash, or the release requirement);
/// 4. a host-registered acpmux daemon (pid + start time) is one of its ancestors;
/// 5. it presents the per-launch secret (`checkSecret`).
/// Checks 1-4 run at accept, before the helper reads a byte, so a plain
/// same-uid client (`nc -U`) is refused without sending anything.
/// Residual (phase 2): a process inside an acpmux agent tree, such as an
/// agent's tool shell, passes checks 3-4 only when it runs the acpmux binary.
enum AdmissionPolicy {
    static func checkIdentity(_ peer: PeerFacts, config: AdmissionConfig?) -> AdmissionRefusal? {
        guard let config else { return .notConfigured }
        guard peer.uid == config.helperUID else { return .foreignUser }
        guard peer.signatureValid else { return .invalidSignature }
        let knownHash = peer.cdhash.map { config.acpmuxCDHashes.contains($0) } ?? false
        let knownRelease = config.acpmuxRequirement != nil && peer.satisfiesRequirement
        guard knownHash || knownRelease else { return .unknownCode }
        guard peer.ancestors.contains(where: config.acpmuxDaemons.contains) else { return .outsideAcpmuxTree }
        return nil
    }

    static func checkSecret(_ presented: Data?, config: AdmissionConfig) -> AdmissionRefusal? {
        guard let presented, !presented.isEmpty else { return .missingSecret }
        return constantTimeEqual(presented, config.secret) && !config.secret.isEmpty ? nil : .wrongSecret
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}
