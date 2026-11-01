import AppKit
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Files the person drops on a chat page or pastes from Finder (`chat.attach.dropped {kind, names}`):
/// for a chat whose folder is on this Mac the page gets their real paths, so a folder, or a file no
/// prompt block takes, goes as a link to where it is instead of a copy. The paths come only from
/// the native drop or paste the page's files came from (``AgentPaneDroppedPaths``): once, within a
/// few seconds, and only for the same files by name.
@MainActor
struct AgentPaneAttachDroppedTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The clock the stash reads, moved by the test.
    private final class Uptime {
        var now: TimeInterval = 1000
    }

    /// A pane whose App says its chat is on this Mac (`local`), or says nothing (nil).
    private final class Rig {
        let model = AgentPaneModel(host: NoHost())
        let clock = Uptime()

        init(local: Bool? = true) {
            let clock = clock
            model.droppedPaths = AgentPaneDroppedPaths(now: { clock.now })
            if let local { model.onLocalPaths = { local } }
        }

        func ask(_ kind: String, _ names: [String]) async -> [String: Any] {
            await model.respond(to: AgentPaneRequest(body: ["method": "chat.attach.dropped", "params": ["kind": kind, "names": names]]))
        }
    }

    private static func errorCode(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    private static func items(_ reply: [String: Any]) -> [[String: Any]]? {
        (reply["value"] as? [String: Any])?["items"] as? [[String: Any]]
    }

    /// A folder `docs` and a file `build.zip` in a fresh temporary folder.
    private static func dropped() throws -> (base: URL, folder: URL, file: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("dropped-\(UUID().uuidString)")
        let folder = base.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("build.zip")
        try Data([0x50, 0x4b, 0x03, 0x04]).write(to: file)
        return (base, folder, file)
    }

    @Test func decodesTheMethod() {
        let request = AgentPaneRequest(body: ["method": "chat.attach.dropped", "params": ["kind": "drop", "names": ["docs", "build.zip"]]])
        #expect(request == .attachDropped(.drop, names: ["docs", "build.zip"]))
        #expect(AgentPageOps.methods["chat.attach.dropped"] == "chat.attach.dropped")
        // The names are the person's files: the log line never shows them.
        #expect(String(describing: request) == "attachDropped")
        #expect(AgentPaneRequest(body: ["method": "chat.attach.dropped", "params": ["kind": "paste", "names": ["a.mov"]]])
            == .attachDropped(.paste, names: ["a.mov"]))
    }

    @Test func refusesAMalformedRequest() {
        let method = "chat.attach.dropped"
        for params: [String: Any] in [
            ["kind": "pick", "names": ["a.zip"]],
            ["kind": "drop", "names": [String]()],
            ["kind": "drop", "names": Array(repeating: "a.zip", count: AgentPaneDroppedPaths.maximumNames + 1)],
            ["kind": "drop", "names": ["a/b.zip"]],
            ["kind": "drop", "names": [".."]],
            ["kind": "drop", "names": ["."]],
            ["kind": "drop"],
        ] {
            #expect(AgentPaneRequest(body: ["method": method, "params": params]) == .unsupported(method), "\(params)")
        }
    }

    /// A drop of a folder and a file answers each one's path, and whether it is a folder.
    @Test func answersTheDroppedPathsAndFolders() async throws {
        let (base, folder, file) = try Self.dropped()
        defer { try? FileManager.default.removeItem(at: base) }
        let rig = Rig()
        rig.model.droppedPaths.stash([folder, file], kind: .drop)
        let reply = await rig.ask("drop", ["docs", "build.zip"])
        #expect(Self.errorCode(reply) == nil, "\(reply)")
        let items = try #require(Self.items(reply))
        #expect(items.compactMap { $0["path"] as? String } == [folder.path, file.path])
        #expect(items.compactMap { $0["folder"] as? Bool } == [true, false])
    }

    /// Files picked in + > Attach files are linked where they are, as a drop's are: a several-GB
    /// video is never streamed into a copy (Leo, 2026-10-31: "video attachments (big attachments?)
    /// still sucks"). A pick's record answers only a pick's ask.
    @Test func aPickInTheFileInputAnswersItsPathsLikeADrop() async throws {
        let (base, _, file) = try Self.dropped()
        defer { try? FileManager.default.removeItem(at: base) }
        let rig = Rig()
        rig.model.droppedPaths.stash([file], kind: .choose)
        #expect(Self.items(await rig.ask("drop", ["build.zip"]))?.isEmpty == true)
        let items = try #require(Self.items(await rig.ask("choose", ["build.zip"])))
        #expect(items.compactMap { $0["path"] as? String } == [file.path])
    }

    /// The page's order of the same files is the order of the answer.
    @Test func answersInThePagesOrder() async throws {
        let (base, folder, file) = try Self.dropped()
        defer { try? FileManager.default.removeItem(at: base) }
        let rig = Rig()
        rig.model.droppedPaths.stash([folder, file], kind: .drop)
        let items = try #require(Self.items(await rig.ask("drop", ["build.zip", "docs"])))
        #expect(items.compactMap { $0["path"] as? String } == [file.path, folder.path])
    }

    /// A name WebKit gives in another Unicode form (é composed, the file system's decomposed) is the same file.
    @Test func matchesNamesInEitherUnicodeForm() async throws {
        let rig = Rig()
        let url = URL(fileURLWithPath: "/tmp/cafe\u{301}.mov")
        rig.model.droppedPaths.stash([url], kind: .drop)
        let items = try #require(Self.items(await rig.ask("drop", ["caf\u{e9}.mov"])))
        #expect(items.compactMap { $0["path"] as? String } == [url.path])
    }

    /// WebKit names a dropped folder (or package) `<name>.zip`, the archive it would make: that is the
    /// folder. A folder and a zip of the same name keep the drop's order.
    @Test func aFolderIsTheZipWebKitNamesIt() async throws {
        let (base, folder, file) = try Self.dropped()
        defer { try? FileManager.default.removeItem(at: base) }
        let rig = Rig()
        rig.model.droppedPaths.stash([folder, file], kind: .drop)
        var items = try #require(Self.items(await rig.ask("drop", ["docs.zip", "build.zip"])))
        #expect(items.compactMap { $0["path"] as? String } == [folder.path, file.path])
        #expect(items.compactMap { $0["folder"] as? Bool } == [true, false])

        let build = base.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        rig.model.droppedPaths.stash([build, file], kind: .drop)
        items = try #require(Self.items(await rig.ask("drop", ["build.zip", "build.zip"])))
        #expect(items.compactMap { $0["path"] as? String } == [build.path, file.path])
        #expect(items.compactMap { $0["folder"] as? Bool } == [true, false])
    }

    /// A dot folder or file (`.github`, `.env`) is asked for by its name like any other.
    @Test func asksForDotFilesToo() async throws {
        #expect(AgentPaneRequest(body: ["method": "chat.attach.dropped", "params": ["kind": "drop", "names": [".github", ".env"]]])
            == .attachDropped(.drop, names: [".github", ".env"]))
        let rig = Rig()
        let url = URL(fileURLWithPath: "/tmp/.env")
        rig.model.droppedPaths.stash([url], kind: .drop)
        let items = try #require(Self.items(await rig.ask("drop", [".env"])))
        #expect(items.compactMap { $0["path"] as? String } == [url.path])
    }

    /// Other names, another count, a second ask or an old drop answer no paths (the page then uploads).
    @Test func answersNothingForOtherFilesTwiceOrLate() async throws {
        let (base, folder, file) = try Self.dropped()
        defer { try? FileManager.default.removeItem(at: base) }
        let rig = Rig()

        rig.model.droppedPaths.stash([folder, file], kind: .drop)
        #expect(Self.items(await rig.ask("drop", ["docs", "other.zip"]))?.isEmpty == true)
        // A miss uses the drop up: the right names after it get nothing either.
        #expect(Self.items(await rig.ask("drop", ["docs", "build.zip"]))?.isEmpty == true)

        rig.model.droppedPaths.stash([folder, file], kind: .drop)
        #expect(Self.items(await rig.ask("drop", ["docs"]))?.isEmpty == true)

        rig.model.droppedPaths.stash([folder, file], kind: .drop)
        #expect(Self.items(await rig.ask("drop", ["docs", "build.zip"]))?.count == 2)
        #expect(Self.items(await rig.ask("drop", ["docs", "build.zip"]))?.isEmpty == true)

        rig.model.droppedPaths.stash([folder, file], kind: .drop)
        rig.clock.now += AgentPaneDroppedPaths.lifetime + 1
        #expect(Self.items(await rig.ask("drop", ["docs", "build.zip"]))?.isEmpty == true)
    }

    /// A paste asks for the paste's files: the drop's stay for the drop.
    @Test func aPasteDoesNotTakeTheDrop() async throws {
        let (base, folder, file) = try Self.dropped()
        defer { try? FileManager.default.removeItem(at: base) }
        let rig = Rig()
        rig.model.droppedPaths.stash([folder, file], kind: .drop)
        #expect(Self.items(await rig.ask("paste", ["docs", "build.zip"]))?.isEmpty == true)
        #expect(Self.items(await rig.ask("drop", ["docs", "build.zip"]))?.count == 2)

        rig.model.droppedPaths.stash([file], kind: .paste)
        #expect(Self.items(await rig.ask("paste", ["build.zip"]))?.compactMap { $0["path"] as? String } == [file.path])
    }

    /// A chat on another machine, or one the App does not call local (moved to Cloud, or not wired),
    /// never gets this Mac's paths.
    @Test func refusedUnlessTheChatIsOnThisMac() async {
        let url = URL(fileURLWithPath: "/tmp/build.zip")
        let remote = Rig()
        remote.model.remoteChat = true
        remote.model.droppedPaths.stash([url], kind: .drop)
        #expect(Self.errorCode(await remote.ask("drop", ["build.zip"])) == "unsupported")

        for local in [false, nil] as [Bool?] {
            let rig = Rig(local: local)
            rig.model.droppedPaths.stash([url], kind: .drop)
            #expect(Self.errorCode(await rig.ask("drop", ["build.zip"])) == "unsupported")
        }
    }

    /// WebKit's Paste in the composer's right-click menu runs the web view's own `paste:`, so a
    /// paste from that menu records the pasteboard's files as Cmd-V does.
    @Test func theContextMenusPasteGoesThroughTheView() {
        let view = NSView()
        let menu = NSMenu()
        // WebKit's own item sends its action to WebKit's menu target, past the view.
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.cut(_:)), keyEquivalent: "")
        paste.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierPaste")
        menu.addItem(paste)
        AgentPaneContextMenu.rebuild(menu, target: nil, devTools: false,
                                     actions: .init(copy: { _ in }, fork: { _ in }, pasteTarget: view))
        let item = menu.items.first { $0.identifier?.rawValue == "WKMenuItemIdentifierPaste" }
        #expect(item?.action == #selector(NSText.paste(_:)))
        #expect(item?.target === view)
    }
}
