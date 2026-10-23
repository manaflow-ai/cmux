import CmuxNextSignposts

/// The registry's ``ActionRunTiming``: `action.perform` around the synchronous run and
/// `action.commit` from its start to the next Core Animation commit (``CommitBoundary``), in Debug
/// and Release. The message fields go to the log system unformatted (``ActionSignpostMessage``).
struct SignpostActionRunTiming: ActionRunTiming {
    private let signposter = Signposter.action

    func time<T>(_ id: ActionID, _ origin: ActionOrigin, inputAge: () -> Double, _ body: () -> T) -> T {
        guard signposter.isEnabled else { return body() }
        let message = ActionSignpostMessage(id: id.rawValue, origin: origin.rawValue, inputAgeMilliseconds: inputAge())
        let commit = signposter.begin(.actionCommit, message)
        let result = signposter.interval(.actionPerform, message, body)
        CommitBoundary().after { [signposter] outcome in signposter.end(.actionCommit, commit, outcome) }
        return result
    }
}
