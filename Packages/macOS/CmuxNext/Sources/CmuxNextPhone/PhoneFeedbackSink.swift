/// Where "Send to Chief" puts a feedback clip. The App implements it with the
/// Home chat (message + attachments); tests record the clips.
@MainActor
public protocol PhoneFeedbackSink: AnyObject {
    func send(_ clip: PhoneFeedbackClip) async throws
}
