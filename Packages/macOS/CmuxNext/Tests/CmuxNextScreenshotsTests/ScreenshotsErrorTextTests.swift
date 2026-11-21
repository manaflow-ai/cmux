import CmuxNextFiles
@testable import CmuxNextScreenshots
import Foundation
import Testing

/// A failed rename or drop says what happened in plain words, never the system's error text
/// (`NSAlert(error:)` printed "The operation couldn’t be completed. (Cocoa error 513.)"). Leo,
/// 2026-11-12: "we want good error states. We don't want busted errors."
struct ScreenshotsErrorTextTests {
    private struct Opaque: Error {}

    @Test func knownFailuresHavePlainWords() {
        #expect(ScreenshotsStrings.reason(POSIXError(.ENOSPC)) == ScreenshotsStrings.reasonNoSpace)
        #expect(ScreenshotsStrings.reason(CocoaError(.fileWriteNoPermission)) == ScreenshotsStrings.reasonPermission)
        #expect(ScreenshotsStrings.reason(FileBrowserError.exists(URL(fileURLWithPath: "/tmp/a.png"))) == ScreenshotsStrings.renameExists)
        #expect(ScreenshotsStrings.reason(FileBrowserError.missing(URL(fileURLWithPath: "/tmp/a.png"))) == ScreenshotsStrings.reasonMissing)
        #expect(ScreenshotsStrings.reason(FileBrowserError.unreadable(URL(fileURLWithPath: "/tmp"), EACCES)) == ScreenshotsStrings.reasonPermission)
    }

    @Test func anUnknownErrorReadsAsTheGenericLine() {
        #expect(ScreenshotsStrings.reason(Opaque()) == ScreenshotsStrings.reasonGeneric)
        #expect(ScreenshotsStrings.reason(FileBrowserError.failed("Operation not permitted (errno 1)")) == ScreenshotsStrings.reasonGeneric)
        for error in [CocoaError(.fileWriteUnknown) as any Error, NSError(domain: "x", code: 3), Opaque()] {
            let text = ScreenshotsStrings.reason(error)
            #expect(!text.contains("Error Domain=") && !text.contains("Code=") && !text.contains("Cocoa error"), "\(text)")
        }
    }

    /// The pane shows no alert built from a raw error.
    @Test func noAlertIsBuiltFromARawError() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CmuxNextScreenshots")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("NSAlert(error:"), "\(file.lastPathComponent)")
        }
    }
}
