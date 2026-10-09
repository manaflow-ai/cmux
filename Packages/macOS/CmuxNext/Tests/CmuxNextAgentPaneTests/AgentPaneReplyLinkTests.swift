import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Path chips (D4): what the host says a reply's path is, and what a click opens. The path is
/// untrusted reply text; every rule here is the host's, so page script cannot skip one.
@MainActor
@Suite struct AgentPaneReplyLinkTests {
    /// A project folder and a folder outside it, with a file in each, a secret, and a link that
    /// points a harmless name at the secret.
    struct Fixture {
        let base: URL
        let project: URL
        let outside: URL
        let home: URL

        init() throws {
            base = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "reply-links-\(UUID().uuidString)")
            project = base.appending(path: "repo")
            outside = base.appending(path: "logs")
            home = base.appending(path: "home")
            let fm = FileManager.default
            for folder in [project.appending(path: "src"), outside, home.appending(path: ".ssh")] {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try Data("x".utf8).write(to: project.appending(path: "src/main.ts"))
            try Data("x".utf8).write(to: project.appending(path: "page.html"))
            try Data("SECRET=1".utf8).write(to: project.appending(path: ".env"))
            try Data("log".utf8).write(to: outside.appending(path: "app.log"))
            try Data("key".utf8).write(to: home.appending(path: ".ssh/id_ed25519"))
            try fm.createSymbolicLink(at: project.appending(path: "notes.txt"), withDestinationURL: home.appending(path: ".ssh/id_ed25519"))
        }

        func remove() { try? FileManager.default.removeItem(at: base) }

        func model(_ setting: AgentPaneReplySetting = .fallback) -> (AgentPaneModel, Box) {
            let model = AgentPaneModel(host: MockAgentPaneHost())
            let box = Box()
            let root = project.path
            model.workspaceRoots = { [root] }
            model.replyLinks.home = home.path
            model.replyLinks.settings = { setting }
            model.replyLinks.revealFolder = { box.revealed.append($0.resolvingSymlinksInPath().path) }
            model.onOpenFile = { url, target in
                box.opened.append((url.resolvingSymlinksInPath().path, target))
                return true
            }
            return (model, box)
        }
    }

    final class Box {
        var opened: [(String, AgentPaneFileTarget)] = []
        var revealed: [String] = []
        var asked: [String] = []
    }

    static func code(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    /// The path the app is handed (`AgentPaneFileOpen.resolve` resolves links, so `/private/var`
    /// reads `/var`).
    static func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    @Test func inspectSaysWhereEachPathIsWithoutLookingOutsideTheRoots() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (model, _) = fixture.model()
        let paths = [
            fixture.project.appending(path: "src/main.ts").path, "src/", fixture.project.appending(path: "nope.ts").path,
            fixture.outside.appending(path: "app.log").path, fixture.outside.appending(path: "missing.log").path,
            fixture.project.appending(path: ".env").path, fixture.project.appending(path: "notes.txt").path, "~/.ssh/id_ed25519",
        ]
        let request = AgentPaneRequest(body: ["method": "link.inspect", "params": ["paths": paths]] as [String: Any])
        let reply = await model.respond(to: request)
        let value = try #require(reply["value"] as? [String: Any])
        let places = try #require(value["paths"] as? [String: [String: Any]])
        #expect(places.mapValues { $0["place"] as? String } == [
            paths[0]: "root", paths[1]: "root", paths[2]: "missing",
            // Outside a root, a file that exists and one that does not look the same.
            paths[3]: "outside", paths[4]: "outside",
            paths[5]: "denied", paths[6]: "denied", paths[7]: "denied",
        ])
        #expect(places[paths[1]]?["folder"] as? Bool == true)
        let policy = try #require(value["policy"] as? [String: String])
        #expect(policy == ["outsideRoots": "open", "remoteImages": "click"])
        // A passive read does not count as the user touching the page.
        #expect(!model.userTouched)
    }

    @Test func aChipInsideTheRootsOpensInTheFilePagesOnlyAfterAGesture() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (model, box) = fixture.model()
        let file = fixture.project.appending(path: "page.html").path
        let request = AgentPaneRequest(body: ["method": "link.openPath", "params": ["path": file]] as [String: Any])
        #expect(Self.code(await model.respond(to: request)) == "link.gesture_required")
        #expect(box.opened.isEmpty)
        model.transport.gestures.record()
        #expect(await model.respond(to: request)["ok"] as? Bool == true)
        // A page type opens as text in the file pages, never in an outside app.
        #expect(box.opened.map(\.0) == [Self.canonical(fixture.project.appending(path: "page.html"))])
        #expect(box.opened.map(\.1) == [.tab])
        // One gesture, one open.
        #expect(Self.code(await model.respond(to: request)) == "link.gesture_required")
        // A folder shows in Finder.
        model.transport.gestures.record()
        _ = await model.respond(to: AgentPaneRequest(body: ["method": "link.openPath", "params": ["path": "src/"]] as [String: Any]))
        #expect(box.revealed == [Self.canonical(fixture.project.appending(path: "src"))])
    }

    @Test func aSecretNeverOpensEvenWithAGestureOrBehindALink() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (model, box) = fixture.model(AgentPaneReplySetting(outsideRoots: .open, remoteImages: .click))
        for path in [fixture.project.appending(path: ".env").path, fixture.project.appending(path: "notes.txt").path,
                     fixture.home.appending(path: ".ssh/id_ed25519").path] {
            model.transport.gestures.record()
            let reply = await model.respond(to: AgentPaneRequest(body: ["method": "link.openPath", "params": ["path": path]] as [String: Any]))
            #expect(Self.code(reply) == "link.path_denied", "\(path)")
        }
        #expect(box.opened.isEmpty)
    }

    /// The default: a chip outside the roots opens on the click, with no sheet (Lawrence
    /// 2026-10-07, "Remove dialogues."). It still needs the gesture.
    @Test func byDefaultAChipOutsideTheRootsOpensOnTheClickWithoutASheet() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let log = fixture.outside.appending(path: "app.log").path
        let request = AgentPaneRequest(body: ["method": "link.openPath", "params": ["path": log]] as [String: Any])
        let (model, box) = fixture.model()
        var sheets = 0
        model.replyLinks.confirmOutside = { _, answer in sheets += 1; answer(false) }
        #expect(Self.code(await model.respond(to: request)) == "link.gesture_required")
        model.transport.gestures.record()
        #expect(await model.respond(to: request)["ok"] as? Bool == true)
        #expect(sheets == 0)
        #expect(box.opened.map(\.0) == [Self.canonical(fixture.outside.appending(path: "app.log"))])
    }

    @Test func outsideTheRootsTheSettingDecides() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let log = fixture.outside.appending(path: "app.log").path
        let request = AgentPaneRequest(body: ["method": "link.openPath", "params": ["path": log]] as [String: Any])

        // text: plain text, nothing opens.
        var (model, box) = fixture.model(AgentPaneReplySetting(outsideRoots: .text, remoteImages: .click))
        model.transport.gestures.record()
        #expect(Self.code(await model.respond(to: request)) == "link.path_outside_roots")
        #expect(box.opened.isEmpty)

        // confirm (an opt-in): the host's sheet asks; Cancel opens nothing, Open opens it.
        (model, box) = fixture.model(AgentPaneReplySetting(outsideRoots: .confirm, remoteImages: .click))
        var answer = false
        model.replyLinks.confirmOutside = { path, reply in
            box.asked.append(path)
            reply(answer)
        }
        model.transport.gestures.record()
        #expect(Self.code(await model.respond(to: request)) == "link.not_confirmed")
        answer = true
        // Without a gesture the sheet never shows.
        #expect(Self.code(await model.respond(to: request)) == "link.gesture_required")
        #expect(box.asked.count == 1)
        model.transport.gestures.record()
        #expect(await model.respond(to: request)["ok"] as? Bool == true)
        #expect(box.asked.count == 2)
        #expect(box.opened.map(\.0) == [Self.canonical(fixture.outside.appending(path: "app.log"))])

        // open: like a path inside, after a gesture.
        (model, box) = fixture.model(AgentPaneReplySetting(outsideRoots: .open, remoteImages: .click))
        model.transport.gestures.record()
        #expect(await model.respond(to: request)["ok"] as? Bool == true)
        #expect(box.opened.count == 1)
    }

    @Test func theParamsContractRefusesAnythingElse() {
        func request(_ method: String, _ params: [String: Any]) -> AgentPaneRequest {
            AgentPaneRequest(body: ["method": method, "params": params] as [String: Any])
        }
        #expect(request("link.openPath", ["path": "/a", "where": "editor"]) == .unsupported("link.openPath"))
        #expect(request("link.openPath", ["path": ""]) == .unsupported("link.openPath"))
        #expect(request("link.openPath", ["path": String(repeating: "a", count: 5000)]) == .unsupported("link.openPath"))
        #expect(request("link.inspect", ["paths": Array(repeating: "/a", count: 65).enumerated().map { "/\($0.offset)" }]) == .unsupported("link.inspect"))
        #expect(request("link.inspect", ["paths": [1]]) == .unsupported("link.inspect"))
        #expect(request("link.inspect", ["paths": ["/a", "/a"]]) == .reply(.inspect(paths: ["/a"], urls: [])))
        #expect(request("browser.openIn", ["url": "javascript:alert(1)", "browserId": "x"]) == .unsupported("browser.openIn"))
        #expect(request("browser.openIn", ["url": "https://u:p@example.com/", "browserId": "x"]) == .unsupported("browser.openIn"))
        #expect(request("browser.openIn", ["url": "file:///etc/passwd", "browserId": "x"]) == .unsupported("browser.openIn"))
        #expect(request("browser.openIn", ["url": "https://example.com/a", "browserId": "x", "app": "/Applications/Terminal.app"])
            == .unsupported("browser.openIn"))
        // Every method is a page op on the page host too.
        for method in AgentPaneReplyRequest.methods {
            #expect(AgentPageOps.all.contains("cmux.agent." + method))
        }
    }
}
