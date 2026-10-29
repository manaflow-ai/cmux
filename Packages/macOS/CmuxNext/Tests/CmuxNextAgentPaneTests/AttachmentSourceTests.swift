import AppKit
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Where an attachment came from (``AttachmentSource``), for its chip's corner icon: only what the
/// system says, never a guess.
@MainActor
struct AttachmentSourceTests {
    private static let own = "com.cmuxterm.app.test"
    /// Installed apps by bundle id, and this app's id.
    private static let apps = AttachmentSourceApps(
        app: { ["com.google.Chrome": "Google Chrome", "com.apple.finder": "Finder",
                "com.apple.screenshot.launcher": "Screenshot", "com.apple.finder.Open-AirDrop": "AirDrop",
                "com.cmuxterm.app.test": "cmux"][$0] },
        ownBundleId: { own })

    @Test func aSourceIsCheckedAsItIsMade() {
        #expect(AttachmentSource(name: " Google Chrome ", bundleId: "com.google.Chrome", site: "github.com")?.name == "Google Chrome")
        #expect(AttachmentSource(name: "") == nil)
        #expect(AttachmentSource(name: String(repeating: "x", count: 65)) == nil)
        #expect(AttachmentSource(name: "A", bundleId: "no dots") == nil)
        #expect(AttachmentSource(name: "A", bundleId: ".com.x") == nil)
        #expect(AttachmentSource(name: "A", bundleId: "com.x;rm") == nil)
        #expect(AttachmentSource(name: "A", site: "GitHub.com") == nil)
        #expect(AttachmentSource(name: "A", site: "a.com/path") == nil)
        let json = AttachmentSource(name: "Finder", bundleId: "com.apple.finder")!.json
        #expect(json == ["name": "Finder", "bundleId": "com.apple.finder"])
    }

    @Test func aChipKeepsItsSourceAndAnOlderListStillReads() throws {
        let source = AttachmentSource(name: "Screenshot", bundleId: "com.apple.screenshot.launcher")
        let chip = AgentPaneWakeState.Attachment(id: "a", kind: "image", name: "a.png", mimeType: "image/png", size: 3, source: source)
        let back = try JSONDecoder().decode(AgentPaneWakeState.Attachment.self, from: JSONEncoder().encode(chip))
        #expect(back.source == source)
        let older = Data(#"{"id":"a","kind":"image","name":"a.png","mimeType":"image/png","size":3}"#.utf8)
        #expect(try JSONDecoder().decode(AgentPaneWakeState.Attachment.self, from: older).source == nil)
    }

    // MARK: Pasteboard

    private typealias Mark = AttachmentPasteboardOrigin.Mark

    @Test func theLastStretchWhoseCountMovedNamesTheWriter() {
        let marks = [Mark(count: 10, front: "com.google.Chrome", capturing: false),
                     Mark(count: 11, front: "com.apple.finder", capturing: false),
                     Mark(count: 11, front: Self.own, capturing: false)]
        // Copied in Chrome, then Finder and cmux came to the front.
        #expect(AttachmentPasteboardOrigin.writer(marks: marks, count: 11, types: [], said: nil) == "com.google.Chrome")
        // Copied again while cmux was in front: cmux.
        #expect(AttachmentPasteboardOrigin.writer(marks: marks, count: 12, types: [], said: nil) == Self.own)
    }

    @Test func aCaptureRunningWhenTheCountMovedIsScreenshot() {
        let marks = [Mark(count: 4, front: "com.google.Chrome", capturing: true),
                     Mark(count: 5, front: "com.google.Chrome", capturing: false),
                     Mark(count: 5, front: Self.own, capturing: false)]
        #expect(AttachmentPasteboardOrigin.writer(marks: marks, count: 5, types: [], said: nil) == "com.apple.screenshot.launcher")
        let source = AttachmentPasteboardOrigin.source(bundleId: "com.apple.screenshot.launcher", apps: Self.apps)
        #expect(source == AttachmentSource(name: "Screenshot", bundleId: "com.apple.screenshot.launcher"))
    }

    @Test func anUnknownWriterIsNone() {
        let marks = [Mark(count: 7, front: "com.google.Chrome", capturing: false)]
        // Copied before the app started: the count never moved while it watched.
        #expect(AttachmentPasteboardOrigin.writer(marks: marks, count: 7, types: [], said: nil) == nil)
        #expect(AttachmentPasteboardOrigin.writer(marks: [], count: 7, types: [], said: nil) == nil)
        // Another device's clipboard, and a tool's own contents.
        #expect(AttachmentPasteboardOrigin.writer(marks: marks, count: 8, types: ["com.apple.is-remote-clipboard"], said: nil) == nil)
        #expect(AttachmentPasteboardOrigin.writer(marks: marks, count: 8, types: ["org.nspasteboard.TransientType"], said: nil) == nil)
        // An app no longer installed.
        #expect(AttachmentPasteboardOrigin.source(bundleId: "com.gone.App", apps: Self.apps) == nil)
    }

    @Test func anAppThatSaysItWroteItIsTakenAtItsWord() {
        let marks = [Mark(count: 1, front: "com.google.Chrome", capturing: false)]
        #expect(AttachmentPasteboardOrigin.writer(marks: marks, count: 2, types: [], said: "com.apple.finder") == "com.apple.finder")
        #expect(AttachmentPasteboardOrigin.writer(marks: marks, count: 2, types: [], said: "not an id") == "com.google.Chrome")
        #expect(AttachmentPasteboardOrigin.source(bundleId: Self.own, apps: Self.apps)?.name == "cmux")
    }

    @Test func cmuxClaimsWhatItCopies() {
        let board = NSPasteboard(name: NSPasteboard.Name("cmux-source-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("x", forType: .string)
        AttachmentPasteboardOrigin.claim(board, bundleId: Self.own)
        #expect(board.string(forType: AttachmentPasteboardOrigin.sourceType) == Self.own)
    }

    // MARK: Files

    private static func plist(_ value: Any) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)) ?? Data()
    }

    private static func file(_ attributes: [String: Data], quarantine: [String: Any]? = nil) -> AttachmentSource? {
        AttachmentSourceFiles.source(attribute: { attributes[$0] }, quarantine: quarantine, apps: apps)
    }

    @Test func aFilesMetadataNamesItsSource() {
        #expect(Self.file([AttachmentSourceFiles.ownMark: Data(Self.own.utf8)]) == .cmux)
        #expect(Self.file(["com.apple.metadata:kMDItemIsScreenCapture": Self.plist(true)])?.name == "Screenshot")
        #expect(Self.file(["com.apple.metadata:kMDItemScreenCaptureType": Self.plist("display")])?.name == "Screenshot")
        let downloaded = Self.file(
            [AttachmentSourceFiles.whereFroms: Self.plist(["https://objects.example-cdn.com/x.png?sig=1", "https://github.com/a/b"])],
            quarantine: [kLSQuarantineAgentBundleIdentifierKey as String: "com.google.Chrome"])
        #expect(downloaded == AttachmentSource(name: "Google Chrome", bundleId: "com.google.Chrome", site: "github.com"))
        let airDropped = Self.file([:], quarantine: [kLSQuarantineAgentBundleIdentifierKey as String: "com.apple.sharingd"])
        #expect(airDropped == AttachmentSource(name: "AirDrop", bundleId: "com.apple.finder.Open-AirDrop"))
    }

    @Test func aFileWhoseMetadataSaysNothingHasNoSource() {
        #expect(Self.file([:]) == nil)
        // Another app's mark is not cmux's.
        #expect(Self.file([AttachmentSourceFiles.ownMark: Data("com.other.app".utf8)]) == nil)
        // A command-line tool that downloaded it is no app.
        #expect(Self.file([:], quarantine: [kLSQuarantineAgentBundleIdentifierKey as String: "com.example.curl"]) == nil)
        #expect(Self.file([:], quarantine: [kLSQuarantineAgentNameKey as String: "Google Chrome"]) == nil)
    }

    @Test func aMarkedFileReadsBack() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID().uuidString).png")
        try Data([0x89, 0x50]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        AttachmentSourceFiles.markOwn(file, bundleId: Self.own)
        #expect(AttachmentSourceFiles.attribute(AttachmentSourceFiles.ownMark, of: file) == Data(Self.own.utf8))
        #expect(AttachmentSourceFiles.source(of: file, apps: Self.apps) == .cmux)
    }

    // MARK: The page's ask

    @Test func eachNameGetsItsFilesSourceElseTheGesturesOnce() {
        let finder = AttachmentSource(name: "Finder", bundleId: "com.apple.finder")
        let urls = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/docs")]
        let shot = AttachmentSource.screenshot
        let sources = AgentPaneModel.sources(for: ["docs.zip", "a.png", "image.png"], urls: urls, gesture: finder) { url in
            url.lastPathComponent == "a.png" ? shot : nil
        }
        #expect(sources == [finder, shot, finder])
        #expect(AgentPaneModel.sources(for: ["a.png"], urls: [], gesture: nil) { _ in shot } == [nil])
    }

    @Test func decodesTheMethods() {
        let request = AgentPaneRequest(body: ["method": "chat.attach.source", "params": ["kind": "paste", "names": ["image.png"]]])
        #expect(request == .attachSource(.paste, names: ["image.png"]))
        #expect(String(describing: request) == "attachSource")
        #expect(AgentPageOps.methods["chat.attach.source"] == "chat.attach.source")
        #expect(AgentPageOps.methods["attachment.sourceIcon"] == "attachment.sourceIcon")
        #expect(AgentPaneRequest(body: ["method": "attachment.sourceIcon", "params": ["bundleId": "com.apple.finder"]])
            == .attachmentSourceIcon("com.apple.finder"))
        for params: [String: Any] in [["kind": "choose", "names": ["a"]], ["kind": "drop", "names": [String]()], ["kind": "drop"]] {
            #expect(AgentPaneRequest(body: ["method": "chat.attach.source", "params": params]) == .unsupported("chat.attach.source"))
        }
        #expect(AgentPaneRequest(body: ["method": "attachment.sourceIcon", "params": ["bundleId": "../x"]]) == .unsupported("attachment.sourceIcon"))
    }

    @Test func cmuxsCaptureSaysItIsCmuxs() {
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        let answer = AgentPaneCapture.answer(png, taken: Date(timeIntervalSince1970: 0))
        #expect(answer["source"] as? [String: String] == AttachmentSource.cmux.json)
    }
}
