public import Darwin

/// Who may take part in a session handoff (`auth.session.handoff`): cmux NIGHTLY giving its signed-in
/// Stack session to another local cmux build of the same macOS user.
///
/// Both ends check the other. The server (NIGHTLY) answers only a client of its own user whose code is
/// a cmux main app signed by cmux's team (``isCmuxApp(_:)``); the client takes a pair only from a server
/// of its own user signed by the team as NIGHTLY (``serverBundleID``). Every check names the process by
/// the audit token the kernel recorded for the connection, never by pid. An ad hoc signed build (the
/// fleet's tagged DEV builds) has no team, so it is refused: a same-user process can make an ad hoc
/// app of any name, and the team signature is the one thing it cannot forge.
public struct SessionHandoffPolicy: Sendable {
    /// The one control socket method that carries a session.
    public static let method = "auth.session.handoff"
    /// cmux's Apple Developer team.
    public static let teamIdentifier = "7WLXT3NR37"
    /// cmux NIGHTLY, the only build that hands its session out.
    public static let serverBundleID = "com.cmuxterm.app.nightly"

    /// The user both ends must run as (this process's own user).
    public let uid: uid_t
    /// The code signature check.
    public let codeCheck: any SessionHandoffCodeChecking

    /// - Parameters:
    ///   - uid: The user both ends must run as. Defaults to this process's.
    ///   - codeCheck: The signature check. Defaults to the Security framework's.
    public init(uid: uid_t = getuid(), codeCheck: any SessionHandoffCodeChecking = SessionHandoffCodeCheck()) {
        self.uid = uid
        self.codeCheck = codeCheck
    }

    /// Whether NIGHTLY may hand its session to `peer`, the client of one connection.
    public func admitsClient(_ peer: SessionHandoffPeer?) -> Bool {
        guard let peer, peer.uid == uid,
              let identifier = codeCheck.signingIdentifier(of: peer.auditToken, teamIdentifier: Self.teamIdentifier) else {
            return false
        }
        return Self.isCmuxApp(identifier)
    }

    /// Whether `peer`, the process listening on the socket a client connected to, is NIGHTLY.
    public func admitsServer(_ peer: SessionHandoffPeer?) -> Bool {
        guard let peer, peer.uid == uid else { return false }
        return codeCheck.signingIdentifier(of: peer.auditToken, teamIdentifier: Self.teamIdentifier) == Self.serverBundleID
    }

    /// Main cmux app bundle ids: the release channels, and DEV and staging builds with or without a tag
    /// of `[a-z0-9]` segments. Never a helper (Computer Use, the bundled `cmux` CLI, signed `cmux`), so
    /// a script cannot run a signed cmux tool to fetch the session.
    public static func isCmuxApp(_ identifier: String) -> Bool {
        let exact: Set<String> = [
            "com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.nightly.cmux-next",
            "com.cmuxterm.app.nightly.cmux-next-stable", "com.cmuxterm.app.rc", "com.cmuxterm.app.debug",
            "com.cmuxterm.app.staging",
        ]
        if exact.contains(identifier) { return true }
        for prefix in ["com.cmuxterm.app.debug.", "com.cmuxterm.app.staging."] where identifier.hasPrefix(prefix) {
            let segments = identifier.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
            return segments.allSatisfy { segment in
                !segment.isEmpty && segment.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
                    && !["cua", "helper"].contains(segment)
            }
        }
        return false
    }
}
