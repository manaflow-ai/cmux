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
public enum ACPHostCapabilities {
    /// The protocol version this host speaks.
    public static let protocolVersion = 1

    /// Builds the `initialize` result.
    ///
    /// - Parameters:
    ///   - clientProtocolVersion: What the client asked for, when it said. The
    ///     reply always names the version this host will actually speak, which
    ///     is the lower of the two: answering with the client's number would
    ///     promise behavior this build does not have.
    ///   - writesEnabled: False for the read-only phase. A client reads this
    ///     instead of discovering the gap by having `session/prompt` rejected
    ///     mid-conversation.
    public static func initializeResult(
        clientProtocolVersion: Int?,
        writesEnabled: Bool = false
    ) -> [String: Any] {
        let negotiated = min(clientProtocolVersion ?? protocolVersion, protocolVersion)
        return [
            "protocolVersion": negotiated,
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
///
/// Spelled out as constants because a typo in a method name is invisible in a
/// test that uses the same typo on both sides.
public enum ACPHostMethod {
    public static let initialize = "initialize"
    public static let authenticate = "authenticate"
    public static let sessionNew = "session/new"
    public static let sessionLoad = "session/load"
    public static let sessionPrompt = "session/prompt"
    public static let sessionCancel = "session/cancel"
    public static let sessionSetMode = "session/set_mode"
    public static let sessionUpdate = "session/update"
    public static let cmuxSessionList = "_cmux/session/list"

    /// The extension methods this build answers, advertised at `initialize`.
    public static let extensionMethodNames = [cmuxSessionList]

    /// Methods ACP defines that this phase does not implement yet, each with
    /// the phase that owns it. A client gets that phase back in the error, so
    /// "not implemented" is actionable instead of just a refusal.
    public static let deferredMethods: [String: String] = [
        sessionNew: "phase 2",
        sessionPrompt: "phase 2",
        sessionCancel: "phase 2",
        sessionSetMode: "phase 3",
    ]
}
