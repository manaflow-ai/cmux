/// Why an action shows nothing until its remote work answers (``ActionEffect/waiting(_:_:)``): the
/// one effect that breaks the accept-first law, so it names its reason and the registry counts its
/// runs (``ActionRegistry/waitingRuns``). The pre-push guardrail `action-wait` refuses a new use.
public nonisolated enum ActionWait: String, Sendable, Hashable, CaseIterable {
    /// The change exists only after a daemon command answers and no local stand-in exists yet:
    /// debt; the fix is a store intent (``ActionEffect/applied(_:)``).
    case daemonEcho
    /// A network service decides the result (a cloud machine, an account, a download).
    case network
    /// Another process decides the result (an installer, an editor, a system service).
    case externalProcess
    /// A folder read off the main actor decides the result (the newest file in a folder).
    case fileSystem
}
