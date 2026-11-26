internal import Foundation

/// Where a clip lands and what it is called.
extension WindowRecordingRequest {
    public static let outputDirectoryName = "cmux-recordings"

    /// The clip's filename when the caller did not pass `out`.
    public func outputFilename(_ name: WindowCaptureOutputName) -> String {
        name.filename(label: label, fileExtension: format.rawValue)
    }
}
