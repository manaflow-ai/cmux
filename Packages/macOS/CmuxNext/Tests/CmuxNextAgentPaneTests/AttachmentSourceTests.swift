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

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

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

    @Test func onlyAPasteboardThatSaysWhoWroteItHasAWriter() {
        #expect(AttachmentSource.claimed(types: ["public.png"], said: "com.apple.finder") == "com.apple.finder")
        // Saying nothing is no writer: the app in front is never taken for it.
        #expect(AttachmentSource.claimed(types: ["public.png"], said: nil) == nil)
        #expect(AttachmentSource.claimed(types: [], said: "not an id") == nil)
        // Another device's clipboard, and a tool's own contents, have none even when they claim one.
        #expect(AttachmentSource.claimed(types: ["com.apple.is-remote-clipboard"], said: "com.apple.finder") == nil)
        #expect(AttachmentSource.claimed(types: ["org.nspasteboard.TransientType"], said: "com.apple.finder") == nil)
        #expect(AttachmentSource.source(bundleId: Self.own, apps: Self.apps)?.name == "cmux")
        #expect(AttachmentSource.source(bundleId: "com.apple.finder", apps: Self.apps)?.name == "Finder")
        // An app no longer installed.
        #expect(AttachmentSource.source(bundleId: "com.gone.App", apps: Self.apps) == nil)
    }

    @Test func cmuxClaimsWhatItCopies() {
        let board = NSPasteboard(name: NSPasteboard.Name("cmux-source-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("x", forType: .string)
        #expect(AttachmentSource.claimed(on: board) == nil)
        AttachmentSource.claim(board, bundleId: Self.own)
        #expect(board.string(forType: AttachmentSource.pasteboardSourceType) == Self.own)
        #expect(AttachmentSource.claimed(on: board) == Self.own)
    }

    @Test func aSourceIsAskedOnlyOfThePersonsOwnDropOrPasteOnce() {
        final class Uptime { var now: TimeInterval = 100 }
        let clock = Uptime()
        let record = AgentPaneDroppedPaths(now: { clock.now })
        #expect(record.source(.paste) == nil)
        record.stashSource([URL(fileURLWithPath: "/tmp/a.png")], claimed: "com.apple.finder", kind: .paste)
        // A drop's record never answers for a paste.
        #expect(record.source(.drop) == nil)
        let taken = record.source(.paste)
        #expect(taken?.urls == [URL(fileURLWithPath: "/tmp/a.png")] && taken?.claimed == "com.apple.finder")
        // Once only.
        #expect(record.source(.paste) == nil)
        record.stashSource([], claimed: nil, kind: .drop)
        clock.now += AgentPaneDroppedPaths.lifetime + 1
        #expect(record.source(.drop) == nil)
    }

    @Test func withNoDropOrPasteTheAskAnswersNoSources() async {
        let model = AgentPaneModel(host: NoHost())
        let answer = await model.attachSource(.paste, names: ["image.png", "notes.txt"], apps: Self.apps)
        #expect((answer["sources"] as? [Any])?.allSatisfy { $0 is NSNull } == true)
        #expect((answer["sources"] as? [Any])?.count == 2)
    }

    // MARK: Files

    private static func plist(_ value: Any) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)) ?? Data()
    }

    private static func file(_ attributes: [String: Data], quarantine: [String: Any]? = nil) -> AttachmentSource? {
        AttachmentSource.source(attribute: { attributes[$0] }, quarantine: quarantine, apps: apps)
    }

    @Test func aFilesMetadataNamesItsSource() {
        #expect(Self.file([AttachmentSource.ownMark: Data(Self.own.utf8)]) == .cmux)
        #expect(Self.file(["com.apple.metadata:kMDItemIsScreenCapture": Self.plist(true)])?.name == "Screenshot")
        #expect(Self.file(["com.apple.metadata:kMDItemScreenCaptureType": Self.plist("display")])?.name == "Screenshot")
        let downloaded = Self.file(
            [AttachmentSource.whereFroms: Self.plist(["https://objects.example-cdn.com/x.png?sig=1", "https://github.com/a/b"])],
            quarantine: [kLSQuarantineAgentBundleIdentifierKey as String: "com.google.Chrome"])
        #expect(downloaded == AttachmentSource(name: "Google Chrome", bundleId: "com.google.Chrome", site: "github.com"))
        let airDropped = Self.file([:], quarantine: [kLSQuarantineAgentBundleIdentifierKey as String: "com.apple.sharingd"])
        #expect(airDropped == AttachmentSource(name: "AirDrop", bundleId: "com.apple.finder.Open-AirDrop"))
    }

    @Test func aFileWhoseMetadataSaysNothingHasNoSource() {
        #expect(Self.file([:]) == nil)
        // Another app's mark is not cmux's.
        #expect(Self.file([AttachmentSource.ownMark: Data("com.other.app".utf8)]) == nil)
        // A command-line tool that downloaded it is no app.
        #expect(Self.file([:], quarantine: [kLSQuarantineAgentBundleIdentifierKey as String: "com.example.curl"]) == nil)
        #expect(Self.file([:], quarantine: [kLSQuarantineAgentNameKey as String: "Google Chrome"]) == nil)
    }

    @Test func aMarkedFileReadsBack() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID().uuidString).png")
        try Data([0x89, 0x50]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        AttachmentSource.markOwn(file, bundleId: Self.own)
        #expect(AttachmentSource.attribute(AttachmentSource.ownMark, of: file) == Data(Self.own.utf8))
        #expect(AttachmentSource.source(of: file, apps: Self.apps) == .cmux)
    }

    // MARK: The page's ask

    @Test func eachNameGetsItsFilesSourceElseThePasteboardsClaim() {
        let finder = AttachmentSource(name: "Finder", bundleId: "com.apple.finder")
        let urls = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/docs")]
        let shot = AttachmentSource.screenshot
        let sources = AgentPaneModel.sources(for: ["docs.zip", "a.png", "image.png"], urls: urls, claimed: finder) { url in
            url.lastPathComponent == "a.png" ? shot : nil
        }
        #expect(sources == [finder, shot, finder])
        #expect(AgentPaneModel.sources(for: ["a.png"], urls: [], claimed: nil) { _ in shot } == [nil])
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
