/// One input sent through cmux during a recording, one line of `events.jsonl`.
public struct PhoneRecordingEvent: Sendable, Hashable, Codable {
    /// Seconds since the recording started; lines up with the video.
    public var at: Double
    /// "tap", "swipe", "text", "button", "open-url", "pasteboard", "appearance", "location", "locale", "install", "launch",
    /// "software-keyboard".
    public var kind: String
    public var point: PhonePoint?
    public var to: PhonePoint?
    /// Text typed, URL opened or button pressed. Clipboard text is not kept.
    public var detail: String?

    /// The event for `input` at `at` seconds (`cmux-phone-core`'s `recording_event`); only its kind when Rust does not answer.
    public init(at: Double, input: PhoneInput) {
        self = (try? PhoneRules.decode(PhoneRecordingEvent.self, "event", "recording_event", ["at": at, "input": input.wire],
                                       what: "the recording event")) ?? PhoneRecordingEvent(at: at, kind: input.kind)
    }

    private init(at: Double, kind: String) {
        self.at = at
        self.kind = kind
    }
}
