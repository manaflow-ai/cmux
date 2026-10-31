/// The voice that reads an agent chat's messages aloud (``AgentPaneReadAloud``): the system's
/// speech synthesizer in the app (``AgentPaneSystemVoice``), a recording fake in tests.
@MainActor
protocol AgentPaneReadAloudVoice: AnyObject {
    /// Starts reading `text` in `language` (a BCP 47 tag such as `en`; nil for the system's), and
    /// calls `finished` once when that utterance ends, on its own or cut off by ``stop()``.
    func speak(_ text: String, language: String?, finished: @escaping @MainActor () -> Void)
    /// Stops whatever it reads, at once.
    func stop()
}
