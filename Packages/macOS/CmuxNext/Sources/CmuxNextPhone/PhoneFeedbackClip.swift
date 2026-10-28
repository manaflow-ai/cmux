public import Foundation

/// A finished recording packaged as product feedback: one Markdown message
/// plus the files to attach (video, poster). The App posts it into the Home
/// chat in one click ("Send to Chief").
public struct PhoneFeedbackClip: Sendable, Hashable {
    public let recording: PhoneRecording
    public let markdown: String
    /// Video first, then the poster frame when there is one.
    public let attachments: [URL]

    /// Throws ``PhoneError/outOfRange(what:)`` for a time or point no whole number holds
    /// (``PhoneService/send(_:to:)`` and the manifest decoder refuse those first).
    public init(_ recording: PhoneRecording, logTail: PhoneLogTail? = nil) throws {
        self.recording = recording
        attachments = [recording.videoURL] + (recording.posterURL.map { [$0] } ?? [])
        markdown = try Self.summary(recording, logTail: logTail)
    }

    /// Builds the clip and reads the log tail from the recording's folder.
    public static func load(_ recording: PhoneRecording) throws -> PhoneFeedbackClip {
        let tail = recording.logURL.flatMap { try? Data(contentsOf: $0) }.map { PhoneLogTail(ndjson: $0) }
        return try PhoneFeedbackClip(recording, logTail: tail)
    }

    static func summary(_ recording: PhoneRecording, logTail: PhoneLogTail?) throws -> String {
        let device = recording.device
        let taps = recording.events.filter { $0.kind == "tap" }.count
        var lines: [String] = []
        let title = String(localized: "phone.feedback.title", defaultValue: "Phone feedback", bundle: .module)
        let length = try clock(recording.duration)
        lines.append("**\(title)**: \(device.name) (\(device.model), \(device.osVersion)) · \(length) · "
            + String(format: String(localized: "phone.feedback.inputs", defaultValue: "%lld inputs, %lld taps", bundle: .module),
                     Int64(truncatingIfNeeded: recording.events.count), Int64(truncatingIfNeeded: taps)))
        let notes = recording.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            lines.append("")
            lines.append(notes)
        }
        if !recording.events.isEmpty {
            lines.append("")
            lines.append(String(localized: "phone.feedback.steps", defaultValue: "Steps:", bundle: .module))
            for event in recording.events.prefix(30) {
                let at = try clock(event.at), step = try describe(event)
                lines.append("- \(at) \(step)")
            }
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
    static func clock(_ seconds: Double) throws -> String {
        let tenths = try whole((seconds * 10).rounded(), "a recording time")
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }

    private static func describe(_ event: PhoneRecordingEvent) throws -> String {
        func point(_ p: PhonePoint?) throws -> String {
            guard let p else { return "" }
            let x = try whole(p.x.rounded(.towardZero), "a point"), y = try whole(p.y.rounded(.towardZero), "a point")
            return "(\(x), \(y))"
        }
        switch event.kind {
        case "tap":
            let at = try point(event.point)
            return "tap \(at)"
        case "swipe":
            let from = try point(event.point), to = try point(event.to)
            return "swipe \(from) → \(to)"
        default: return [event.kind, event.detail.map { "`\($0)`" }].compactMap { $0 }.joined(separator: " ")
        }
    }

    /// `value` (already whole) as an `Int`; a typed error, not a trap, when no `Int` holds it.
    private static func whole(_ value: Double, _ what: String) throws -> Int {
        guard let whole = Int(exactly: value) else { throw PhoneError.outOfRange(what: what) }
        return whole
    }
}
