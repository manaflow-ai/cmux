import CoreServices
import Foundation
import Testing
@testable import CmuxNextBrowser

/// The one download policy of both engines: files go only to the Downloads
/// folder (safe, unique names) or the file the person chose, every finished
/// file is quarantined, and no finished file is opened.
@MainActor
@Suite struct BrowserDownloadPolicyTests {
    private let downloads = URL(filePath: "/Users/me/Downloads", directoryHint: .isDirectory)

    @Test func theChosenFileWinsElseTheDownloadsFolder() {
        let chosen = URL(filePath: "/Users/me/Desktop/x.bin")
        #expect(BrowserDownloadPolicy.destination(chosen: chosen, suggestedFilename: "../../evil", directory: downloads) { _ in true }
            == chosen)
        let taken: Set<String> = ["/Users/me/Downloads/a.txt", "/Users/me/Downloads/a (1).txt"]
        let next = BrowserDownloadPolicy.destination(chosen: nil, suggestedFilename: "a.txt", directory: downloads) {
            taken.contains($0.path(percentEncoded: false))
        }
        #expect(next?.path(percentEncoded: false) == "/Users/me/Downloads/a (2).txt")
    }

    /// A page-supplied name never leaves the Downloads folder and carries no
    /// path separators, leading dots, control or format characters.
    @Test func pageNamesAreSanitized() {
        func name(_ raw: String) -> String {
            BrowserDownloadPolicy.destination(chosen: nil, suggestedFilename: raw, directory: downloads) { _ in false }?
                .path(percentEncoded: false) ?? ""
        }
        #expect(name("/etc/passwd") == "/Users/me/Downloads/passwd")
        #expect(name("../../.ssh/authorized_keys") == "/Users/me/Downloads/authorized_keys")
        #expect(name("...hidden") == "/Users/me/Downloads/hidden")
        #expect(name("in\tvoice\u{0}.pdf") == "/Users/me/Downloads/invoice.pdf")
        #expect(name("photo\u{202E}gpj.exe") == "/Users/me/Downloads/photogpj.exe")
        #expect(name("a:b") == "/Users/me/Downloads/a-b")
        #expect(name("\u{7}") == "/Users/me/Downloads/download")
        #expect(name("") == "/Users/me/Downloads/download")
    }

    /// The only step after a download is quarantine: cmux never opens a
    /// downloaded file.
    @Test func finishedFilesAreQuarantinedAndNeverOpened() {
        let file = URL(filePath: "/Users/me/Downloads/a.zip")
        let source = URL(string: "https://e.com/a.zip")
        #expect(BrowserDownloadPolicy.completionSteps(destination: file, source: source) == [.quarantine(file: file, source: source)])
        #expect(BrowserDownloadPolicy.completionSteps(destination: nil, source: source).isEmpty)
    }

    @Test func quarantinePropertiesNameTheSourceAndTheAgent() {
        let source = URL(string: "https://e.com/a.zip")
        let properties = BrowserDownloadPolicy.quarantineProperties(source: source, agentName: "cmux", agentBundleID: "com.cmuxterm.app.next")
        #expect(properties[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeWebDownload as String)
        #expect(properties[kLSQuarantineAgentNameKey as String] as? String == "cmux")
        #expect(properties[kLSQuarantineAgentBundleIdentifierKey as String] as? String == "com.cmuxterm.app.next")
        #expect(properties[kLSQuarantineDataURLKey as String] as? URL == source)
        // A data: or file: source is not recorded as an origin.
        let local = BrowserDownloadPolicy.quarantineProperties(source: URL(string: "data:text/plain,x"), agentName: "cmux", agentBundleID: nil)
        #expect(local[kLSQuarantineDataURLKey as String] == nil)
    }

    /// A finished download of either engine carries `com.apple.quarantine`
    /// on disk (`BrowserDownload.complete`, which both engines call).
    @Test func aFinishedDownloadIsQuarantinedOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "nxbp-quarantine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "a.txt")
        try Data("x".utf8).write(to: file)
        let item = BrowserDownload(sourceURL: URL(string: "https://e.com/a.txt"), filename: "a.txt")
        item.destination = file
        item.complete(.finished)
        #expect(getxattr(file.path(percentEncoded: false), "com.apple.quarantine", nil, 0, 0, 0) > 0)
        let values = try file.resourceValues(forKeys: [.quarantinePropertiesKey])
        #expect(values.quarantineProperties?[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeWebDownload as String)
    }
}
