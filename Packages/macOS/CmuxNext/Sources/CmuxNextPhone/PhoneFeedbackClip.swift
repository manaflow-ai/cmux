import CmuxNextCompat
public import Foundation

/// A finished recording packaged as product feedback: one Markdown message
/// plus the files to attach (video, poster). The App posts it into the Home
/// chat in one click ("Send to Chief").
public struct PhoneFeedbackClip: Sendable, Hashable {
    public let recording: PhoneRecording
    public let markdown: String
    /// Video first, then the poster frame when there is one.
    public let attachments: [URL]

    public init(_ recording: PhoneRecording, logTail: PhoneLogTail? = nil) {
        self.recording = recording
        attachments = [recording.videoURL] + (recording.posterURL.map { [$0] } ?? [])
        markdown = Self.summary(recording, logTail: logTail)
    }

    /// Builds the clip and reads the log tail from the recording's folder.
    public static func load(_ recording: PhoneRecording) -> PhoneFeedbackClip {
        let tail = recording.logURL.flatMap { try? Data(contentsOf: $0) }.map { PhoneLogTail(ndjson: $0) }
        return PhoneFeedbackClip(recording, logTail: tail)
    }

    /// The summary's count of recorded inputs and taps.
    static func inputs(_ inputs: Int, taps: Int,
                       preferredLocalizations: [String] = Bundle.module.preferredLocalizations, locale: Locale = .current) -> String {
        Bundle.module.localizedString(forKey: "phone.feedback.inputs", value: "Inputs: %1$lld, taps: %2$lld", table: nil,
                                      arguments: [.count(inputs), .count(taps)], preferredLocalizations: preferredLocalizations,
                                      locale: locale)
    }

    static func summary(_ recording: PhoneRecording, logTail: PhoneLogTail?) -> String {
        let device = recording.device
        let taps = recording.events.filter { $0.kind == "tap" }.count
        var lines: [String] = []
        let title = String(localized: "phone.feedback.title", defaultValue: "Phone feedback", bundle: .module)
        lines.append("**\(title)**: \(device.name) (\(device.model), \(device.osVersion)) · \(clock(recording.duration)) · "
            + inputs(recording.events.count, taps: taps))
        let notes = recording.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            lines.append("")
            lines.append(notes)
        }
        if !recording.events.isEmpty {
            lines.append("")
            lines.append(String(localized: "phone.feedback.steps", defaultValue: "Steps:", bundle: .module))
            for event in recording.events.prefix(30) { lines.append("- \(clock(event.at)) \(describe(event))") }
            if recording.events.count > 30 { lines.append("- …") }
        }
        if let logTail, !logTail.lines.isEmpty {
            lines.append("")
            lines.append(String(localized: "phone.feedback.logErrors", defaultValue: "Log errors:", bundle: .module))
            lines.append("```")
            for line in logTail.lines { lines.append("[\(line.level)] \(line.process): \(line.message)") }
            lines.append("```")
        }
        lines.append("")
        lines.append(String(localized: "phone.feedback.folder", defaultValue: "Recording folder:", bundle: .module)
            + " [\(recording.id)](\(recording.folder.absoluteString))")
        return lines.joined(separator: "\n")
    }

    /// `0:07.4`
    static func clock(_ seconds: Double) -> String {
        let tenths = Int((seconds * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }

    private static func describe(_ event: PhoneRecordingEvent) -> String {
        func point(_ p: PhonePoint?) -> String { p.map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "" }
        switch event.kind {
        case "tap": return "tap \(point(event.point))"
        case "swipe": return "swipe \(point(event.point)) → \(point(event.to))"
        default: return [event.kind, event.detail.map { "`\($0)`" }].compactMap { $0 }.joined(separator: " ")
        }
    }
}
