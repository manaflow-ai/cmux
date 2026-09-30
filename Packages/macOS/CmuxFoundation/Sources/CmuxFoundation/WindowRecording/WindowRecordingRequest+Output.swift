public import Foundation

/// Where a recording lands and what it is called.
///
/// Recordings follow the screenshot convention (a sortable timestamp plus a
/// short unique suffix, under one directory in the temporary directory) so the
/// two kinds of capture can be listed together and cleaned up together.
extension WindowRecordingRequest {
    public static let outputDirectoryName = "cmux-recordings"

    /// `2026-09-28T07-14-03Z_1a2b3c4d`: sorts by time, unique per recording.
    public static func recordingIdentifier(date: Date, uuid: UUID = UUID()) -> String {
        let timestamp = ISO8601DateFormatter().string(from: date)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "+", with: "_")
        return "\(timestamp)_\(uuid.uuidString.prefix(8).lowercased())"
    }

    /// The clip's filename when the caller did not pass `out`: the label, if
    /// any, then the recording identifier, then the format's extension.
    public func outputFilename(identifier: String) -> String {
        let sanitized = WindowRecordingLabel(label).value
        let stem = sanitized.isEmpty ? identifier : "\(sanitized)_\(identifier)"
        return "\(stem).\(format.rawValue)"
    }
}
