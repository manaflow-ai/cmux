public import Foundation

/// What one capture file is called: a sortable timestamp, a short unique
/// suffix, and the caller's label when it gave one.
///
/// Recordings and stills share this, and each lands in one directory under the
/// temporary directory, so the two kinds of capture can be listed together and
/// cleaned up together.
public struct WindowCaptureOutputName: Sendable, Equatable {
    /// `2026-09-28T07-14-03Z_1a2b3c4d`: sorts by time, unique per capture.
    public let identifier: String

    public init(date: Date = Date(), uuid: UUID = UUID()) {
        let timestamp = ISO8601DateFormatter().string(from: date)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "+", with: "_")
        identifier = "\(timestamp)_\(uuid.uuidString.prefix(8).lowercased())"
    }

    /// Adopts an identifier a caller already holds, so a file name and the
    /// capture it belongs to keep the same one.
    public init(identifier: String) {
        self.identifier = identifier
    }

    /// `<label>_<identifier>.<extension>`, or just the identifier when there is
    /// no usable label. The label goes through `WindowRecordingLabel`, so a
    /// path separator in it cannot escape the directory.
    public func filename(label: String, fileExtension: String) -> String {
        let sanitized = WindowRecordingLabel(label).value
        let stem = sanitized.isEmpty ? identifier : "\(sanitized)_\(identifier)"
        return "\(stem).\(fileExtension)"
    }
}
