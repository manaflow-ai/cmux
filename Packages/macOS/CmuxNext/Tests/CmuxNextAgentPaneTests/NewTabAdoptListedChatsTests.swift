import Foundation
import Testing
import WebKit
@testable import CmuxNextAgentPane

/// Perf-lead issue 11 (every create commits in < 10 ms on the key): Cmd-T, Cmd-N's first page
/// and every recycle adopt a prewarmed New Tab page, and the adoption JSON-encodes the page's
/// context into one `acpmux-newtab-adopt` script on the key's turn. That context carried the
/// chats a page listed last (`warm`, up to `AgentPaneNewTab.maximumWarmBytes`, 512 KB of JSON text,
/// escaped again inside the context), yet a page that listed its own chats drops carried ones
/// (webviews newtab/warmSnapshot.ts `listedOnce`), and a page posts `newTab.warm` only after it
/// listed them. Such a page gets no carried chats again; one that has not listed (still loading,
/// or a new document after `ready`) still gets them for its first frame, and the model keeps
/// them for the page's own handshake.
@Suite(.serialized)
@MainActor
struct NewTabAdoptListedChatsTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private final class Scripts {
        var all: [String] = []
        /// The adoption scripts sent since the last `clear()`.
        var adoptions: [String] { all.filter { $0.contains("acpmux-newtab-adopt") } }
        func clear() { all.removeAll() }
    }

    /// A carried chat list whose title marks it in a script.
    private static let warm = #"{"sessions":[{"sessionId":"carried-1","displayTitle":"Carried chat marker","updatedAt":1}]}"#
    private static let marker = "Carried chat marker"

    private static func page(cwd: String) -> AgentPaneNewTab {
        var page = AgentPaneNewTab(kind: .agent, cwd: cwd)
        page.warm = warm
        return page
    }

    @Test func aPageThatListedItsOwnChatsIsNotSentTheCarriedOnesAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "adopt-listed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data("<html><body></body></html>".utf8).write(to: file)
        let model = AgentPaneModel(host: NoHost(), newTab: AgentPaneNewTab(kind: .agent))
        let view = try #require(AgentPaneView(model: model, source: .bundled(file)))
        let scripts = Scripts()
        view.evaluateScript = { scripts.all.append($0) }
        let saved = AgentPaneNewTab.warmed
        defer { AgentPaneNewTab.warmed = saved }

        // A spare that has not listed its chats yet: the adoption carries them for its first frame.
        view.adoptNewTab(Self.page(cwd: "first-folder"))
        #expect(scripts.adoptions.count == 1)
        #expect(scripts.adoptions.allSatisfy { $0.contains(Self.marker) }, "a page with no list of its own got no carried chats")

        // The page listed its own chats (it posts them only then).
        _ = await model.respond(to: .newTabWarm(Self.warm))
        scripts.clear()
        view.adoptNewTab(Self.page(cwd: "second-folder"))
        #expect(scripts.adoptions.count == 1, "the adoption sent no context")
        #expect(scripts.adoptions.allSatisfy { $0.contains("second-folder") })
        #expect(!scripts.adoptions.contains { $0.contains(Self.marker) },
                "a page that listed its own chats was sent the carried ones again on the key's turn")
        // Its model keeps them: a handshake of the same page answers with the whole context.
        #expect(model.newTab?.warm == Self.warm)

        // A new document (its `ready`) has listed nothing: its next adoption carries them again.
        _ = await model.respond(to: .ready)
        scripts.clear()
        view.adoptNewTab(Self.page(cwd: "third-folder"))
        #expect(scripts.adoptions.count == 1)
        #expect(scripts.adoptions.allSatisfy { $0.contains(Self.marker) }, "a reloaded page got no carried chats")
    }
}
