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
    /// The CLIs' error code for a machine whose daemon did not answer `identify` before the copy began (its link was coming back).
    public static let notAnswering = "machine_not_answering"

    /// Whether an answer (`ok`, `error_code`, `side`) is the machine's older daemon refusing it:
    /// ``code`` about the machine, never this Mac's own daemon (`side` `source`).
    public static func updatesBeforeCopyingAgain(ok: Bool, errorCode: String?, side: String?) -> Bool {
        !ok && errorCode == code && side != "source"
    }

    /// Updates a machine before using a capability that its current daemon does not advertise.
    /// The update restarts the daemon, so this waits, up to `relink`, for `holds` itself (read from the
    /// new handshake), not just for the link to change: a new link may come up before its handshake
    /// carries the capability, and opening then was refused although the update had worked (capture at
    /// a799d97a, 2026-11-02). If the update cannot run or the capability does not arrive in time, this
    /// returns and the caller's existing capability refusal remains the final result.
    @MainActor
    public static func updateBeforeUsingCapability(
        holds: @escaping @MainActor @Sendable () -> Bool,
        relink: Duration = .seconds(90),
        update: @escaping @MainActor @Sendable () async -> Bool
    ) async {
        guard !holds() else { return }
        guard await update() else { return }
        _ = await CloudWait.holds(within: relink, until: holds)
    }

    /// Runs `copy` on the machine's link socket (`socket`, nil when not connected: `notConnected` is thrown); when
    /// its answer (read by `answer`) is the machine's older daemon refusing it (``updatesBeforeCopyingAgain(ok:errorCode:side:)``)
    /// and `update` updated the machine (true), runs it once more. Otherwise the first answer stands: nothing else updates it.
    /// A machine that did not answer `identify` (``notAnswering``: no copy began) is copied once more after its link's handshake
    /// changes, up to `reconnect`: in the capture of run 42157718918 the link was refused at 03:49:10 and 03:49:16, came back at
    /// 03:49:22, and `identify` got no answer at 03:49:27. Only the copy runs again; the chat's prompt is never sent again here.
    /// A link that does not change in time leaves the first answer; a cancelled wait throws, and `stillOurs` (the start's account
    /// check) throws when the account changed meanwhile: neither copies again.
    ///
    /// The update restarts the machine's daemon and its link comes back on a new socket: copying again on the
    /// first one failed with "cannot connect to …/cmux-link-….sock: No such file or directory" (capture at
    /// ff3f8c9b, 2026-11-01). So the second copy waits, up to `relink`, for `link` (the connection's handshake
    /// key) to change from what it was before the update, and reads the socket again.
    @MainActor
    public static func copy<Answer>(socket: () async -> String?, link: @escaping @MainActor @Sendable () -> String?, notConnected: any Error,
                                    relink: Duration = .seconds(90), reconnect: Duration = .seconds(20), stillOurs: () throws -> Void = {}, _ copy: (String) async throws -> Answer,
                                    answer: (Answer) -> (ok: Bool, errorCode: String?, side: String?), update: () async -> Bool) async throws -> Answer {
        guard let path = await socket() else { throw notConnected }
        let before = link()
        let first = try await copy(path)
        let read = answer(first)
        if !read.ok, read.errorCode == notAnswering {
            let relinked = await CloudWait.holds(within: reconnect) { link().map { $0 != before } ?? false }
            try Task.checkCancellation()
            try stillOurs()
            guard relinked else { return first }
            guard let again = await socket() else { throw notConnected }
            try Task.checkCancellation()
            try stillOurs()
            return try await copy(again)
        }
        guard updatesBeforeCopyingAgain(ok: read.ok, errorCode: read.errorCode, side: read.side), await update() else { return first }
        _ = await CloudWait.holds(within: relink) { link().map { $0 != before } ?? false }
        guard let again = await socket() else { throw notConnected }
        return try await copy(again)
    }
}
