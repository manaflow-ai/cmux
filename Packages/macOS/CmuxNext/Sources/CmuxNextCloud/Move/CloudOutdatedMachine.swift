/// A Cloud machine whose cmux-tui is older than the app's: the CLIs Move to Cloud, Bring Back Local
/// and a chat start's folder copy run (cmux-tui `link/machine_gate.rs`) refuse it with ``code``.
///
/// A new machine's image may carry an older cmux-tui than the app, and the automatic update its
/// first handshake queued may not have run yet. A chat start's copy (`cmux link start-chat copy`)
/// refused that way updates the machine to the app's own build and copies once more, on its new link (``copy(socket:link:notConnected:relink:_:answer:update:)``),
/// instead of failing the person's first send with "Update the machine".
public struct CloudOutdatedMachine {
    public init() {}
    /// The CLIs' error code for a daemon too old for the verb.
    public static let code = "machine_outdated"

    /// Whether an answer (`ok`, `error_code`, `side`) is the machine's older daemon refusing it:
    /// ``code`` about the machine, never this Mac's own daemon (`side` `source`).
    public static func updatesBeforeCopyingAgain(ok: Bool, errorCode: String?, side: String?) -> Bool {
        !ok && errorCode == code && side != "source"
    }

    /// Updates a machine before using a capability that its current daemon does not advertise.
    /// The update restarts the daemon, so the capability must be read from the new handshake rather
    /// than from the old connection. If the update cannot run or the new link does not arrive before
    /// `relink`, this returns and the caller's existing capability refusal remains the final result.
    @MainActor
    public static func updateBeforeUsingCapability(
        holds: @escaping @MainActor @Sendable () -> Bool,
        link: @escaping @MainActor @Sendable () -> String?,
        relink: Duration = .seconds(90),
        update: @escaping @MainActor @Sendable () async -> Bool
    ) async {
        guard !holds() else { return }
        let before = link()
        guard await update() else { return }
        _ = await CloudWait.holds(within: relink) {
            link().map { $0 != before } ?? false
        }
    }

    /// Runs `copy` on the machine's link socket (`socket`, nil when not connected: `notConnected` is thrown); when
    /// its answer (read by `answer`) is the machine's older daemon refusing it (``updatesBeforeCopyingAgain(ok:errorCode:side:)``)
    /// and `update` updated the machine (true), runs it once more. Otherwise the first answer stands: nothing else updates it.
    ///
    /// The update restarts the machine's daemon and its link comes back on a new socket: copying again on the
    /// first one failed with "cannot connect to …/cmux-link-….sock: No such file or directory" (capture at
    /// ff3f8c9b, 2026-11-01). So the second copy waits, up to `relink`, for `link` (the connection's handshake
    /// key) to change from what it was before the update, and reads the socket again.
    @MainActor
    public static func copy<Answer>(socket: () async -> String?, link: @escaping @MainActor @Sendable () -> String?, notConnected: any Error,
                                    relink: Duration = .seconds(90), _ copy: (String) async throws -> Answer,
                                    answer: (Answer) -> (ok: Bool, errorCode: String?, side: String?), update: () async -> Bool) async throws -> Answer {
        guard let path = await socket() else { throw notConnected }
        let before = link()
        let first = try await copy(path)
        let read = answer(first)
        guard updatesBeforeCopyingAgain(ok: read.ok, errorCode: read.errorCode, side: read.side), await update() else { return first }
        _ = await CloudWait.holds(within: relink) { link().map { $0 != before } ?? false }
        guard let again = await socket() else { throw notConnected }
        return try await copy(again)
    }
}
