internal import Foundation

/// Where a still lands and what it is called.
extension WindowScreenshotRequest {
    /// Stills keep the directory the DEBUG screenshot command has always used,
    /// so anything that already collects cmux screenshots finds these too.
    public static let outputDirectoryName = "cmux-screenshots"

    /// The still's filename when the caller did not pass `out`.
    public func outputFilename(_ name: WindowCaptureOutputName) -> String {
        name.filename(label: label, fileExtension: format.preferredFileExtension)
    }
}
