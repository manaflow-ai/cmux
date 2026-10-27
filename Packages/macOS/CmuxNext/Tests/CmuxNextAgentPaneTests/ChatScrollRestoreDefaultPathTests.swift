import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// cx-6bgzj on the host a chat actually opens on. `ChatScrollRestoreTests` covers the shared page
/// host (``AgentPageProvider``), but `agent.pageHost` is off by default, so an agent pane's page
/// talks to the pane's own host (``AgentPaneBridge``) instead, and that is the path a reader is on.
/// The page sends the same two ops either way — `callNative` falls back to the `agentSession`
/// handler when there is no page client — so this holds that path to the same promise: a chat the
/// reader left in the middle reopens there.
///
/// What the pane's own host was missing is the chat's *durable* place. A tab open at a clean quit
/// already came back where it was, through its wake state (`AgentPaneWakeState`, which goes
/// straight to `window.cmuxAcpmuxActions` and so needed neither host); the per-chat store these
/// ops write is what survives a crash, and what a different tab — or a tab closed and opened
/// again — reads.
@Suite(.serialized)
@MainActor
struct ChatScrollRestoreDefaultPathTests {
    /// What the pane's own host answers the page, as ``AgentPaneBridge`` routes it.
    static func call(_ method: String, _ params: [String: Any]) -> [String: Any] {
        AgentPaneScrollAnchors.reply(to: method, params: params)
    }

    static func value(_ reply: [String: Any]) -> Any? {
        #expect(reply["ok"] as? Bool == true, "the host refused the request: \(reply)")
        return reply["value"]
    }

    @Test func aChatReopensWhereItRestedWithThePageHostOff() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "anchors-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            AgentPaneScrollAnchors.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }
        // This run: the reader scrolls chat s-1 up and it rests on row user-42.
        await AgentPaneScrollAnchors.shared?.flushed()  // the last store\'s saves are on disk
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: directory, work: BackgroundWork(label: "test.scroll-anchors"))
        _ = Self.value(Self.call("chat.scrollAnchor", ["sessionId": "s-1", "rowId": "user-42", "offset": 120.5]))

        // A fresh store — the next run after a crash, or another tab in this one — reads it back,
        // for that chat only.
        await AgentPaneScrollAnchors.shared?.flushed()  // the last store\'s saves are on disk
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: directory, work: BackgroundWork(label: "test.scroll-anchors"))
        let place = Self.value(Self.call("chat.scrollAnchor.get", ["sessionId": "s-1"])) as? [String: Any]
        #expect(place?["rowId"] as? String == "user-42")
        #expect(place?["offset"] as? Double == 120.5)
        #expect(Self.value(Self.call("chat.scrollAnchor.get", ["sessionId": "s-2"])) is NSNull)

        // Back at the latest message: the place is forgotten, so the chat opens following the reply.
        _ = Self.value(Self.call("chat.scrollAnchor", ["sessionId": "s-1", "rowId": NSNull(), "offset": 0]))
        await AgentPaneScrollAnchors.shared?.flushed()  // the last store\'s saves are on disk
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: directory, work: BackgroundWork(label: "test.scroll-anchors"))
        #expect(Self.value(Self.call("chat.scrollAnchor.get", ["sessionId": "s-1"])) is NSNull)
    }

    /// Both hosts read and write the one store, so a chat opened on either reopens where the other
    /// left it — a pane with `agent.pageHost` on beside one without, or the setting changed between
    /// two runs.
    @Test func thePageHostAndThePanesOwnHostShareTheOneStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "anchors-shared-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            AgentPaneScrollAnchors.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }
        await AgentPaneScrollAnchors.shared?.flushed()  // the last store\'s saves are on disk
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: directory, work: BackgroundWork(label: "test.scroll-anchors"))

        // Written on the pane's own host, read on the page host.
        _ = Self.value(Self.call("chat.scrollAnchor", ["sessionId": "s-3", "rowId": "user-7", "offset": 8]))
        let provider = AgentPageProvider { _ in nil }
        let read = try await provider.call(
            AgentPageOps.namespace + "chat.scrollAnchor.get",
            params: .object(["sessionId": .string("s-3")]),
            context: PageCallContext(page: PageDescriptor.agent.id))
        #expect(read == .object(["rowId": .string("user-7"), "offset": .number(8)]))

        // And the other way: written on the page host, read on the pane's own.
        _ = try await provider.call(
            AgentPageOps.namespace + "chat.scrollAnchor",
            params: .object(["sessionId": .string("s-4"), "rowId": .string("user-9"), "offset": .number(3)]),
            context: PageCallContext(page: PageDescriptor.agent.id))
        let back = Self.value(Self.call("chat.scrollAnchor.get", ["sessionId": "s-4"])) as? [String: Any]
        #expect(back?["rowId"] as? String == "user-9")
    }

    @Test func aRequestWithoutAChatIsRefusedAndNothingIsKept() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "anchors-refuse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            AgentPaneScrollAnchors.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }
        await AgentPaneScrollAnchors.shared?.flushed()  // the last store\'s saves are on disk
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: directory, work: BackgroundWork(label: "test.scroll-anchors"))
        #expect(Self.call("chat.scrollAnchor.get", [:])["ok"] as? Bool == false)
        #expect(Self.call("chat.scrollAnchor", ["sessionId": ""])["ok"] as? Bool == false)
        #expect(Self.call("chat.scrollAnchor.forget", ["sessionId": "s-5"])["ok"] as? Bool == false)
        // Refused, and nothing written under any of those chats.
        #expect(AgentPaneScrollAnchors.shared?.anchor(for: "s-5") == nil)
        #expect(AgentPaneScrollAnchors.shared?.anchor(for: "") == nil)
    }

    /// The routing, not only the answer. ``AgentPaneModel`` has no case for either op, so the pane's
    /// own host has to send them to this seam; take that out of ``AgentPaneBridge`` and a chat
    /// stops keeping its place again, which is the bug.
    ///
    /// A `WKScriptMessage` cannot be made outside WebKit, so this drives the seam the handler
    /// calls — `AgentPaneBridge.chatPlaceReply(for:)`, which takes the same `message.body` — and
    /// not the handler itself. That leaves the one call site uncovered by this test, so
    /// ``theHandlerStillCallsThatSeam`` reads it out of the source instead.
    @Test func thePanesOwnHostRoutesTheseOpsHereBecauseTheModelHasNoneForThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "anchors-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            AgentPaneScrollAnchors.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }
        await AgentPaneScrollAnchors.shared?.flushed()  // the last store\'s saves are on disk
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: directory, work: BackgroundWork(label: "test.scroll-anchors"))

        // What the host does with a page message, body and all: it writes, and it reads back.
        let wrote = try #require(AgentPaneBridge.chatPlaceReply(
            for: ["method": "chat.scrollAnchor",
                  "params": ["sessionId": "s-6", "rowId": "user-3", "offset": 9.0]] as [String: Any]))
        #expect(wrote["ok"] as? Bool == true)
        let read = try #require(AgentPaneBridge.chatPlaceReply(
            for: ["method": "chat.scrollAnchor.get", "params": ["sessionId": "s-6"]] as [String: Any]))
        #expect((read["value"] as? [String: Any])?["rowId"] as? String == "user-3")

        // Anything else is the model's: the host passes it on rather than answering it here.
        // `chat.unsentDraft` is a real op `AgentPaneRequest` decodes, so this says what it means to:
        // an op the model owns passes through, rather than merely that an unknown name does.
        #expect(AgentPaneBridge.chatPlaceReply(for: ["method": "chat.unsentDraft", "params": ["sessionId": "s-6"]] as [String: Any]) == nil)
        #expect(AgentPaneBridge.chatPlaceReply(for: ["method": "chat.scrollAnchor.forget"]) == nil)
        #expect(AgentPaneBridge.chatPlaceReply(for: "not a message") == nil)

        // And the model really has no route of its own, so the branch above is not dead code.
        for method in ["chat.scrollAnchor", "chat.scrollAnchor.get"] {
            let request = AgentPaneRequest(body: ["method": method, "params": ["sessionId": "s-6"]] as [String: Any])
            guard case .unsupported(let named) = request else {
                Issue.record("\(method) now decodes to \(request), so the host should stop intercepting it")
                continue
            }
            #expect(named == method)
        }
    }

    /// The one line the test above cannot reach: `WKScriptMessage` has no public initializer, so
    /// no test can send the handler a message, and every other test here calls the seam directly.
    /// Delete the handler's branch and all of them stay green while a chat silently stops keeping
    /// its place — the bug this suite exists for. So the call site is read out of the source.
    ///
    /// Renaming either symbol is fine; this test then names what to rewrite it to.
    @Test func theHandlerStillCallsThatSeam() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 6 { root.deleteLastPathComponent() }
        let bridge = root.appending(path: "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneBridge.swift")
        // Read, not guessed: a missing or unreadable file fails rather than passing vacuously.
        let source = try String(contentsOf: bridge, encoding: .utf8)
        guard let handler = source.range(of: "func userContentController(") else {
            Issue.record("AgentPaneBridge no longer has a userContentController handler")
            return
        }
        // Inside the handler, not merely somewhere in the file: the next doc comment ends the slice,
        // which today is the one on `reply(for:)`. Delete that doc comment and the slice widens to
        // the rest of the file, so this would stop proving *where* the call is — it would still
        // fail on the regression it exists for, since `chatPlaceReply` appears nowhere else here.
        let rest = source[handler.lowerBound...]
        let body = rest.range(of: "\n    /// ").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
        #expect(body.contains("chatPlaceReply"),
                """
                AgentPaneBridge.userContentController no longer calls chatPlaceReply, so the page's \
                chat.scrollAnchor and chat.scrollAnchor.get reach AgentPaneModel, which has no case \
                for them: a chat stops reopening where the reader left it. Route them again, or \
                give AgentPaneModel the two ops and update this test.
                """)
    }
}
