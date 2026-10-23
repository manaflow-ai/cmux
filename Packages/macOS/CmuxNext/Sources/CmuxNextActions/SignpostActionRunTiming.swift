import CmuxNextSignposts

/// The App's ``ActionRunTiming``: `action.perform` around the synchronous run and `action.commit`
/// from its start to the next Core Animation commit (``CommitBoundary``), plus `action.gate`
/// around a confirmation or argument gate, in Debug and Release. The message fields go to the log
/// system unformatted (``ActionSignpostMessage``).
///
/// Built once at the composition root (`AppServices`) and passed to
/// ``ActionRegistry/standard(runTiming:)``; tests use ``NoActionRunTiming`` or a recorder.
public struct SignpostActionRunTiming: ActionRunTiming {
    /// The always-on action signposts.
    public init() {}

    public func time<T>(_ id: ActionID, _ origin: ActionOrigin, inputAge: () -> Double, _ body: () -> T) -> T {
        let signposter = Signposter.action
        guard signposter.isEnabled else { return body() }
        let message = ActionSignpostMessage(id: id.rawValue, origin: origin.rawValue, inputAgeMilliseconds: inputAge())
        let commit = signposter.begin(.actionCommit, message)
        let result = signposter.interval(.actionPerform, message, body)
        CommitBoundary().after { [signposter] outcome in signposter.end(.actionCommit, commit, outcome) }
        return result
    }

    public func beginGate(_ id: ActionID, _ origin: ActionOrigin, inputAge: () -> Double) -> (@MainActor () -> Void)? {
        let signposter = Signposter.action
        guard signposter.isEnabled else { return nil }
        let message = ActionSignpostMessage(id: id.rawValue, origin: origin.rawValue, inputAgeMilliseconds: inputAge())
        let gate = signposter.begin(.actionGate, message)
        return { [signposter] in signposter.end(.actionGate, gate) }
    }
}
