public import Foundation

/// A finished recording packaged as product feedback: one Markdown message
/// plus the files to attach (video, poster). The App posts it into the Home
/// chat in one click ("Send to Chief"). `cmux-phone-core`'s `feedback_clip` writes both; Swift passes its localized strings.
public struct PhoneFeedbackClip: Sendable, Hashable {
    public let recording: PhoneRecording
    public let markdown: String
    /// Video first, then the poster frame when there is one.
    public let attachments: [URL]

    /// `log`: the recording's `device-log.ndjson`, whose newest error lines the message quotes.
    public init(_ recording: PhoneRecording, log: Data? = nil) {
        self.recording = recording
        var fields: [String: Any] = ["recording": PhoneRules.field(PhoneRecordingWire(recording)),
                                     "folder_url": recording.folder.absoluteString, "strings": Self.strings]
        if let log { fields["log_ndjson"] = PhoneRules.text(log) }
        let clip = try? PhoneRules.reply(Clip.self, "feedback_clip", fields, what: "the feedback clip")
        markdown = clip?.markdown ?? ""
        attachments = (clip?.attachments ?? [recording.video]).map { recording.folder.appendingPathComponent($0) }
    }

    /// Builds the clip and reads the log from the recording's folder.
    public static func load(_ recording: PhoneRecording) -> PhoneFeedbackClip {
        PhoneFeedbackClip(recording, log: recording.logURL.flatMap { try? Data(contentsOf: $0) })
    }

    private static var strings: [String: String] {
        ["title": String(localized: "phone.feedback.title", defaultValue: "Phone feedback", bundle: .localizedModule),
         "inputs": String(localized: "phone.feedback.inputs", defaultValue: "%lld inputs, %lld taps", bundle: .localizedModule),
         "steps": String(localized: "phone.feedback.steps", defaultValue: "Steps:", bundle: .localizedModule),
         "log_errors": String(localized: "phone.feedback.logErrors", defaultValue: "Log errors:", bundle: .localizedModule),
         "folder": String(localized: "phone.feedback.folder", defaultValue: "Recording folder:", bundle: .localizedModule)]
    }

    private struct Clip: Decodable {
        let markdown: String
        let attachments: [String]
    }
}
