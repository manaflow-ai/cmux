import AppKit
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Where an attachment came from (``AttachmentSource``), for its chip's corner icon: only what the
/// system says, never a guess.
@MainActor
struct AttachmentSourceTests {
    nonisolated private static let own = "com.cmuxterm.app.test"
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

    /// Whether this process reaches a pasteboard server: a fleet test step often does not, and there
    /// every write fails and every read returns nil (aws-m4pro-1 and -7, 2026-10-31).
    nonisolated private static let hasPasteboard: Bool = {
        let board = NSPasteboard(name: NSPasteboard.Name("cmux-source-probe-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        return board.setString("probe", forType: .string) && board.string(forType: .string) == "probe"
    }()

    /// A 4 x 4 red picture, as Screenshot Tab copies one.
    private static func picture() throws -> NSImage {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return NSImage(cgImage: try #require(context.makeImage()), size: .zero)
    }

    /// The item cmux writes carries the picture's own types and the source together, so the source is
    /// on the item a paste reads. Needs no pasteboard server.
    @Test func theCopiedItemCarriesThePictureAndItsSource() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("cmux-source-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let image = try Self.picture()
        let item = AttachmentSource.item(for: image, on: board, source: Self.own)
        let imageTypes = image.writableTypes(for: board)
        #expect(imageTypes.contains(.tiff))
        #expect(Set(item.types).isSubset(of: Set(imageTypes + [AttachmentSource.pasteboardSourceType])))
        #expect(item.types.contains(.tiff) && item.types.contains(AttachmentSource.pasteboardSourceType))
        #expect(item.string(forType: AttachmentSource.pasteboardSourceType) == Self.own)
        let tiff = try #require(item.data(forType: .tiff))
        #expect(NSImage(data: tiff)?.size == NSSize(width: 4, height: 4))
        // No source: only the picture's types.
        #expect(!AttachmentSource.item(for: image, on: board, source: nil).types.contains(AttachmentSource.pasteboardSourceType))
    }

    @Test(.enabled(if: hasPasteboard, "needs a pasteboard server")) func cmuxClaimsWhatItCopies() {
        let board = NSPasteboard(name: NSPasteboard.Name("cmux-source-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("x", forType: .string)
        #expect(AttachmentSource.claimed(on: board) == nil)
        #expect(AttachmentSource.write(["y" as NSString], to: board, bundleId: Self.own))
        #expect(board.string(forType: .string) == "y")
        #expect(board.string(forType: AttachmentSource.pasteboardSourceType) == Self.own)
        #expect(AttachmentSource.claimed(on: board) == Self.own)
        // The source is on the item the contents are on, the one a paste reads.
        #expect(board.pasteboardItems?.count == 1)
        #expect(board.pasteboardItems?.first?.string(forType: AttachmentSource.pasteboardSourceType) == Self.own)
        // An id that is no bundle id is never written as a source.
        #expect(AttachmentSource.write(["z" as NSString], to: board, bundleId: "not an id"))
        #expect(board.string(forType: .string) == "z")
        #expect(AttachmentSource.claimed(on: board) == nil)
    }

    /// Screenshot Tab's copy: a picture, written with cmux as its source, pastes as a picture and
    /// says cmux wrote it.
    @Test(.enabled(if: hasPasteboard, "needs a pasteboard server"))
    func aCopiedPictureStillPastesAsAPictureAndSaysItIsCmuxs() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("cmux-source-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        #expect(AttachmentSource.write([try Self.picture()], to: board, bundleId: Self.own))
        #expect(board.pasteboardItems?.count == 1)
        #expect(board.canReadObject(forClasses: [NSImage.self], options: nil))
        let pasted = board.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage]
        #expect(pasted?.first?.size == NSSize(width: 4, height: 4))
        #expect(AttachmentSource.claimed(on: board) == Self.own)
    }

    @Test func aSourceIsAskedOnlyOfThePersonsOwnDropOrPasteOnce() {
        final class Uptime { var now: TimeInterval = 100 }
        let clock = Uptime()
        let record = AgentPaneDroppedPaths(now: { clock.now })
        #expect(record.source(.paste, names: ["a.png"]) == nil)
        record.stashSource([URL(fileURLWithPath: "/tmp/a.png")], items: 1, claimed: "com.apple.finder", kind: .paste)
        // A drop's record never answers for a paste.
        #expect(record.source(.drop, names: ["a.png"]) == nil)
        // An ask for files the paste did not bring answers nothing, and leaves the record.
        #expect(record.source(.paste, names: ["b.png"]) == nil)
        #expect(record.source(.paste, names: ["a.png", "a.png"]) == nil)
        // A drop of a file and a picture names both: the file by its URL, the picture by the claim.
        record.stashSource([URL(fileURLWithPath: "/tmp/c.png")], items: 2, claimed: nil, kind: .drop)
        #expect(record.source(.drop, names: ["c.png", "image.png"])?.urls == [URL(fileURLWithPath: "/tmp/c.png")])
        let taken = record.source(.paste, names: ["a.png"])
        #expect(taken?.urls == [URL(fileURLWithPath: "/tmp/a.png")] && taken?.claimed == "com.apple.finder")
        // Once only.
        #expect(record.source(.paste, names: ["a.png"]) == nil)
        // A pane moved to another chat forgets every gesture's record, a drop's and a paste's: the
        // next chat can't learn where the last chat's files came from. A draft keeps its chips'
        // sources itself (the draft and wake state), not through this record.
        record.stashSource([URL(fileURLWithPath: "/tmp/d.png")], items: 1, claimed: nil, kind: .drop)
        record.stashSource([URL(fileURLWithPath: "/tmp/e.png")], items: 1, claimed: "com.apple.finder", kind: .paste)
        record.clearForSessionChange()
        #expect(record.source(.drop, names: ["d.png"]) == nil)
        #expect(record.source(.paste, names: ["e.png"]) == nil)
        // The next chat's own gesture answers as before.
        record.stashSource([URL(fileURLWithPath: "/tmp/f.png")], items: 1, claimed: "com.apple.finder", kind: .paste)
        let next = record.source(.paste, names: ["f.png"])
        #expect(next?.urls == [URL(fileURLWithPath: "/tmp/f.png")] && next?.claimed == "com.apple.finder")
        // A pick in the file input: its files by their URLs, with no claim, for that pick's ask only.
        record.stashSource([URL(fileURLWithPath: "/tmp/g.png")], items: 1, claimed: nil, kind: .choose)
        #expect(record.source(.paste, names: ["g.png"]) == nil)
        let chosen = record.source(.choose, names: ["g.png"])
        #expect(chosen?.urls == [URL(fileURLWithPath: "/tmp/g.png")] && chosen?.claimed == nil)
        // A pasted picture (no file): only as many files as the pasteboard held items.
        record.stashSource([], items: 1, claimed: "com.google.Chrome", kind: .paste)
        #expect(record.source(.paste, names: ["image.png", "other.png"]) == nil)
        #expect(record.source(.paste, names: ["image.png"])?.claimed == "com.google.Chrome")
        // No files and no claim: nothing to answer.
        record.stashSource([], items: 3, claimed: nil, kind: .drop)
        #expect(record.source(.drop, names: ["image.png"]) == nil)
        record.stashSource([], items: 1, claimed: "com.apple.finder", kind: .drop)
        clock.now += AgentPaneDroppedPaths.lifetime + 1
        #expect(record.source(.drop, names: ["image.png"]) == nil)
    }

    /// An ask that reaches the host late, for a gesture taken before the record it finds, answers
    /// nothing and leaves that newer gesture its own record (two quick pastes of a file of one name).
    @Test func aLateAskForAnOlderGestureNeverTakesTheNewerRecord() {
        final class Clocks { var uptime: TimeInterval = 100; var wall: TimeInterval = 1_793_000_000 }
        let clocks = Clocks()
        let record = AgentPaneDroppedPaths(now: { clocks.uptime }, wall: { clocks.wall })
        let first = clocks.wall
        record.stashSource([URL(fileURLWithPath: "/tmp/one/shot.png")], items: 1, claimed: nil, kind: .paste)
        // The page took the first paste, and its ask is held up. A second paste of a file of the same
        // name replaces the record a second later.
        clocks.uptime += 1
        clocks.wall += 1
        let second = clocks.wall
        record.stashSource([URL(fileURLWithPath: "/tmp/two/shot.png")], items: 1, claimed: "com.apple.finder", kind: .paste)
        // The first paste's ask arrives now: it is older than the record, so it gets nothing.
        #expect(record.source(.paste, names: ["shot.png"], gestureAt: first) == nil)
        // The second paste's own ask still finds its record.
        let taken = record.source(.paste, names: ["shot.png"], gestureAt: second)
        #expect(taken?.urls == [URL(fileURLWithPath: "/tmp/two/shot.png")] && taken?.claimed == "com.apple.finder")
        // The page reads its clock in whole milliseconds after the record was made: that answers.
        record.stashSource([URL(fileURLWithPath: "/tmp/three.png")], items: 1, claimed: nil, kind: .drop)
        #expect(record.source(.drop, names: ["three.png"], gestureAt: clocks.wall - 0.0009) != nil)
    }

    /// Two gestures of one kind a few milliseconds apart: the older one's late ask is older than the
    /// newer record by more than the page clock's rounding, so it never takes that record.
    @Test func anAskAFewMillisecondsOlderThanTheRecordAnswersNothing() {
        final class Clocks { var uptime: TimeInterval = 100; var wall: TimeInterval = 1_793_000_000 }
        let clocks = Clocks()
        let record = AgentPaneDroppedPaths(now: { clocks.uptime }, wall: { clocks.wall })
        let older = clocks.wall
        clocks.uptime += 0.01
        clocks.wall += 0.01
        record.stashSource([URL(fileURLWithPath: "/tmp/newer/shot.png")], items: 1, claimed: nil, kind: .paste)
        #expect(record.source(.paste, names: ["shot.png"], gestureAt: older) == nil)
        // The newer paste's own ask, its clock read in whole milliseconds, still finds it.
        let own = (clocks.wall * 1000).rounded(.down) / 1000
        #expect(record.source(.paste, names: ["shot.png"], gestureAt: own) != nil)
    }

    /// A Chromium drop is recorded after its page took the drop (the page's drop message), dated by
    /// its drag's entry: its own ask, made between the two, still finds it.
    @Test func aChromiumDropsOwnAskFindsItsRecord() {
        final class Clocks { var uptime: TimeInterval = 100; var wall: TimeInterval = 1_793_000_000 }
        let clocks = Clocks()
        let record = AgentPaneDroppedPaths(now: { clocks.uptime }, wall: { clocks.wall })
        let entered = clocks.wall
        // The page takes the drop 2 s after the drag entered, and asks; the host hears of the drop a
        // little later still.
        let gestureAt = entered + 2
        clocks.wall = entered + 2.2
        record.stashSource([URL(fileURLWithPath: "/tmp/shot.png")], items: 1, claimed: nil, kind: .drop, madeAt: entered)
        #expect(record.source(.drop, names: ["shot.png"], gestureAt: gestureAt)?.urls == [URL(fileURLWithPath: "/tmp/shot.png")])
        // Undated, the same record would be newer than the gesture, and its own ask would get nothing.
        record.stashSource([URL(fileURLWithPath: "/tmp/shot.png")], items: 1, claimed: nil, kind: .drop)
        #expect(record.source(.drop, names: ["shot.png"], gestureAt: gestureAt) == nil)
    }

    @Test func theAskCarriesTheGesturesTime() {
        let request = AgentPaneRequest(body: ["method": "chat.attach.source",
                                              "params": ["kind": "paste", "names": ["a.png"], "gestureAt": 1_793_000_000_500]])
        #expect(request == .attachSource(.paste, names: ["a.png"], gestureAt: 1_793_000_000.5))
    }

    @Test func onlyAnAppThisMacNamedAsASourceHasAnIcon() throws {
        let suite = "attachment-source-icons-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let icons = AttachmentSourceIcons(defaults: defaults, ownBundleId: Self.own)
        // Finder is installed on every Mac, but no source named it: no icon, so a page can't ask.
        #expect(icons.dataURL("com.apple.finder") == nil)
        icons.noteAnswered("com.apple.finder")
        #expect(icons.dataURL("com.apple.finder")?.hasPrefix("data:image/png;base64,") == true)
        // Kept for the next launch.
        #expect(AttachmentSourceIcons(defaults: defaults, ownBundleId: Self.own).dataURL("com.apple.finder") != nil)
    }

    @Test func withNoDropOrPasteTheAskAnswersNoSources() async {
        let model = AgentPaneModel(host: NoHost())
        let answer = await model.attachSource(.paste, names: ["image.png", "notes.txt"], apps: Self.apps)
        let sources = (answer["value"] as? [String: Any])?["sources"] as? [Any]
        #expect(sources?.allSatisfy { $0 is NSNull } == true)
        #expect(sources?.count == 2)
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
        // The file input's pick asks for its source, and where its files are (a chat on this Mac
        // links them in place instead of streaming a copy).
        #expect(AgentPaneRequest(body: ["method": "chat.attach.source", "params": ["kind": "choose", "names": ["a.png"]]])
            == .attachSource(.choose, names: ["a.png"]))
        #expect(AgentPaneRequest(body: ["method": "chat.attach.dropped", "params": ["kind": "choose", "names": ["a.png"]]])
            == .attachDropped(.choose, names: ["a.png"]))
        for params: [String: Any] in [["kind": "pick", "names": ["a"]], ["kind": "drop", "names": [String]()], ["kind": "drop"]] {
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
