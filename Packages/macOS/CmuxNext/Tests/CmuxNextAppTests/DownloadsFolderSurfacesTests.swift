@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextSettings
import Foundation
import Testing

/// `debug.downloads` reports the folder downloads go to (`DownloadDestination.defaultDirectory`, which
/// "Show Downloads folder" also opens), so a fleet kit can refuse to run a "nothing was downloaded" check
/// against a build that saves elsewhere (the check then passed with no file looked at).
@MainActor @Suite struct DownloadsFolderSurfacesTests {
    private let moved = URL(filePath: "/tmp/cmux-kit-downloads", directoryHint: .isDirectory)

    @Test func debugDownloadsReportsTheFolderDownloadsGoTo() {
        let reply = DebugDownloads.handle([:], list: BrowserDownloadList(), folder: moved)
        #expect(reply.objectValue?["folder"]?.stringValue == moved.path(percentEncoded: false))
    }
}
