import CmuxNextCompat
import Darwin
public import Foundation
import Security

/// The process at the other end of a connected unix socket, read on that very descriptor
/// (cx-fcaq, cx-l2ai). A caller that sends a secret checks the connection it writes on, never
/// a probe connection: a same-uid process could take the socket path between the two.
///
/// - `uid`: `LOCAL_PEERCRED`;
/// - `pid` and `executablePath`: `LOCAL_PEERPID`, then `proc_pidpath` with symlinks resolved;
/// - the code-signing checks use the peer's audit token (`LOCAL_PEERTOKEN`), not its pid, so a
///   reused pid cannot stand in for it.
public nonisolated struct UnixSocketPeer: Sendable {
    /// The peer's process id (`LOCAL_PEERPID`).
    public let pid: pid_t
    /// The peer's user id (`LOCAL_PEERCRED`).
    public let uid: uid_t
    /// The peer executable's path, symlinks resolved.
    public let executablePath: String
    private let auditToken: Data

    /// `LOCAL_PEERTOKEN` (sys/un.h).
    private static let localPeerToken: Int32 = 0x006

    /// Nil when any of the peer's facts cannot be read.
    public init?(descriptor: Int32) {
        var credentials = xucred()
        var credentialsSize = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &credentialsSize) == 0,
              credentials.cr_version == XUCRED_VERSION else { return nil }
        var pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize) == 0, pid > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        var token = audit_token_t()
        var tokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, Self.localPeerToken, &token, &tokenSize) == 0 else { return nil }
        self.pid = pid
        uid = credentials.cr_uid
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        executablePath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        auditToken = withUnsafeBytes(of: &token) { Data($0) }
    }

    /// Whether the peer runs `executable` (symlinks resolved on both sides).
    public func runs(_ executable: URL) -> Bool {
        executablePath == executable.resolvingSymlinksInPath().path
    }

    /// Whether the peer's code, named by its audit token, satisfies the code requirement `text`.
    /// Checked blocking calls (they wait for the code signing daemon): call it on a lane.
    public func satisfies(_ text: String, fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
        var code: SecCode?
        guard blockingSecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: auditToken] as CFDictionary, [], &code,
                                                     fileID: fileID, line: line) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            return false
        }
        return blockingCall(.systemCall, fileID: fileID, line: line) { SecCodeCheckValidity(code, [], requirement) } == errSecSuccess
    }

    /// Apple-anchored and signed by `team`, with exactly `identifier` when one is given.
    public func signed(team: String, identifier: String? = nil) -> Bool {
        let plain = { (text: String) in
            !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
        }
        guard plain(team), identifier.map(plain) ?? true else { return false }
        var text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        if let identifier { text = "identifier \"\(identifier)\" and " + text }
        return satisfies(text)
    }
}
