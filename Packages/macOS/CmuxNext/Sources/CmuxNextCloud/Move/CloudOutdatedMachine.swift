/// A Cloud machine whose cmux-tui is older than the app's: the CLIs Move to Cloud, Bring Back Local
/// and a chat start's folder copy run (cmux-tui `link/machine_gate.rs`) refuse it with ``code``.
///
/// A new machine's image may carry an older cmux-tui than the app, and the automatic update its
/// first handshake queued may not have run yet. A chat start's copy (`cmux link start-chat copy`)
/// refused that way updates the machine to the app's own build and copies once more (``copy(_:answer:update:)``),
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

    /// Runs `copy`; when its answer (read by `answer`) is the machine's older daemon refusing it
    /// (``updatesBeforeCopyingAgain(ok:errorCode:side:)``) and `update` updated the machine (true),
    /// runs it once more. Otherwise the first answer stands: nothing else updates the machine.
    public static func copy<Answer>(_ copy: () async throws -> Answer, answer: (Answer) -> (ok: Bool, errorCode: String?, side: String?),
                                    update: () async -> Bool) async throws -> Answer {
        let first = try await copy()
        let read = answer(first)
        guard updatesBeforeCopyingAgain(ok: read.ok, errorCode: read.errorCode, side: read.side), await update() else { return first }
        return try await copy()
    }
}
