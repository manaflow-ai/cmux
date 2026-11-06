import AVFoundation

/// The system voice for Read aloud: one `AVSpeechSynthesizer` the app owns, so stopping it never
/// depends on a web view that may have closed or hibernated mid-message (user, 2026-10-29).
@MainActor
final class AgentPaneSystemVoice: NSObject, AgentPaneReadAloudVoice, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    /// Each utterance's end, by its identity; an utterance's end arrives after it stopped.
    private var ends: [ObjectIdentifier: @MainActor () -> Void] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, language: String?, finished: @escaping @MainActor () -> Void) {
        let utterance = AVSpeechUtterance(string: text)
        if let language, let voice = AVSpeechSynthesisVoice(language: language) { utterance.voice = voice }
        ends[ObjectIdentifier(utterance)] = finished
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func ended(_ id: ObjectIdentifier) {
        ends.removeValue(forKey: id)?()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id) }
    }
}
