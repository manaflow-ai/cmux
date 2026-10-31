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

    public init(at: Double, input: PhoneInput) {
        self.at = at
        kind = input.kind
        switch input {
        case .tap(let point): self.point = point
        case .swipe(let from, let to, _): point = from; self.to = to
        case .text(let text): detail = text
        case .button(let button): detail = button.rawValue
        case .openURL(let url): detail = url.absoluteString
        case .pasteboard, .softwareKeyboard: break
        case .appearance(let appearance): detail = appearance.rawValue
        case .location(let latitude, let longitude): detail = "\(latitude),\(longitude)"
        case .locale(let identifier): detail = identifier
        case .install(let app): detail = app.lastPathComponent
        case .launch(let app): detail = app
        }
    }
}
