public import Foundation

/// Where a recording lands and what it is called.
///
/// Recordings follow the screenshot convention (a sortable timestamp plus a
/// short unique suffix, under one directory in the temporary directory) so the
/// two kinds of capture can be listed together and cleaned up together.
public struct WindowRecordingOutputNaming: Sendable {
    public static let directoryName = "cmux-recordings"
    /// Stills keep the directory the DEBUG screenshot command has always used,
    /// so anything that already collects cmux screenshots finds these too.
    public static let screenshotDirectoryName = "cmux-screenshots"

    /// `2026-09-28T07-14-03Z_1a2b3c4d`: sorts by time, unique per recording.
    public static func identifier(date: Date, uuid: UUID = UUID()) -> String {
        let timestamp = ISO8601DateFormatter().string(from: date)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "+", with: "_")
        return "\(timestamp)_\(uuid.uuidString.prefix(8).lowercased())"
    }

    public static func filename(
        label: String,
        identifier: String,
        format: WindowRecordingRequest.Format
    ) -> String {
        filename(label: label, identifier: identifier, fileExtension: format.rawValue)
    }

    public static func filename(
        label: String,
        identifier: String,
        fileExtension: String
    ) -> String {
        let sanitized = WindowRecordingLabel(label).value
        let stem = sanitized.isEmpty ? identifier : "\(sanitized)_\(identifier)"
        return "\(stem).\(fileExtension)"
    }
}
