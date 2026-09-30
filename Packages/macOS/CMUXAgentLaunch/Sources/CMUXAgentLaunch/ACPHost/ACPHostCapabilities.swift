import Foundation

/// What `cmux acp` tells a client it can do at `initialize`.
///
/// Two decisions are encoded here and both are deliberate.
///
/// First, cmux declares no `fs.*` and no `terminal.*` client requirements. A
/// sandboxed ACP agent asks its client to read and write files on its behalf;
/// cmux's agents are ordinary CLIs running on the real filesystem with their
/// own tools. Proxying their I/O through the client would be slower, lossier,
/// and would misreport who touched the disk.
///
/// Second, the cmux-specific flags live under `_meta`, not under a top-level
/// `_cmux` key. ACP reserves underscore prefixes on *method* names for
/// extensions and `_meta` on *objects*, so `_meta.cmux` is the sanctioned
/// place for a capability a client has to feature-detect.
public struct ACPHostCapabilities: Sendable {
    /// The protocol version this host speaks.
    public let protocolVersion: Int

    /// Whether this host advertises write operations.
    public let writesEnabled: Bool

    /// Creates the capability set for this host.
    ///
    /// - Parameter writesEnabled: False for the read-only phase. A client
    ///   reads this instead of discovering the gap by having `session/prompt`
    ///   rejected mid-conversation.
    public init(writesEnabled: Bool = false) {
        protocolVersion = 1
        self.writesEnabled = writesEnabled
    }

    /// Builds the `initialize` result.
    ///
    /// - Parameter clientProtocolVersion: What the client asked for, when it
    ///   said. If the Agent supports the requested version, it MUST respond
    ///   with the same version. Otherwise, the Agent MUST respond with the
    ///   latest version it supports. This host supports one version, so its
    ///   own version is always returned.
    public func initializeResult(clientProtocolVersion: Int?) -> [String: Any] {
        // Kept as a local read so phase 2 can log a mismatch without changing
        // the response contract.
        _ = clientProtocolVersion
        return [
            "protocolVersion": protocolVersion,
            "agentCapabilities": [
                // Host mode exists to attach to sessions that are already
                // running, which is exactly what loadSession is for.
                "loadSession": true,
                // Everything here is false while the host is read-only: a
                // prompt cannot carry an image if a prompt cannot be sent.
                "promptCapabilities": [
                    "image": false,
                    "audio": false,
                    "embeddedContext": false,
                ],
            ],
            // Empty rather than absent: a client that checks the list finds it
            // and skips the authenticate step instead of guessing.
            "authMethods": [],
            "_meta": [
                "cmux": [
                    "version": 1,
                    "sessions": true,
                    "writes": writesEnabled,
                    // Surface binding and focus are their own methods and are
                    // not in this phase; a client must not call them yet.
                    "surfaces": false,
                    "extensionMethods": ACPHostMethod.extensionMethodNames,
                ],
            ],
        ]
    }
}

/// Every method name this host recognizes, in one place.
public enum ACPHostMethod: String, CaseIterable, Sendable {
    case initialize
    case authenticate
    case sessionNew = "session/new"
    case sessionLoad = "session/load"
    case sessionPrompt = "session/prompt"
    case sessionCancel = "session/cancel"
    case sessionSetMode = "session/set_mode"
    case sessionUpdate = "session/update"
    case cmuxSessionList = "_cmux/session/list"

    /// The extension methods this build answers, advertised at `initialize`.
    public static let extensionMethodNames = [cmuxSessionList.rawValue]

    /// Methods ACP defines that this phase does not implement yet, each with
    /// the phase that owns it. A client gets that phase back in the error, so
    /// "not implemented" is actionable instead of just a refusal.
    public static let deferredMethods: [String: String] = [
        sessionNew.rawValue: "phase 2",
        sessionPrompt.rawValue: "phase 2",
        sessionCancel.rawValue: "phase 2",
        sessionSetMode.rawValue: "phase 3",
    ]
}
