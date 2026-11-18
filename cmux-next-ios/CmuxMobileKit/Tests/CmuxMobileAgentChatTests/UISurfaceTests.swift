import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// Agent UI surfaces (`cmux.ui-surface/1`, plans/cmux-next/agent-ui-surfaces-DESIGN.md) on the phone:
/// where a tool call carries one, how leniently it reads, the rows it makes behind the Labs flag, and
/// the calls a card's presses make.
@MainActor
@Suite struct UISurfaceTests {
    @Test func everySampleDecodes() {
        for sample in UISurfaceFixtures.all {
            #expect(UISurface(json: sample.surface) != nil, "\(sample.name)")
        }
        let traveler = UISurface(json: UISurfaceFixtures.json(UISurfaceFixtures.travelerForm))
        #expect(traveler?.root?.children?.map(\.type) == ["text", "field", "field", "field", "button"])
        #expect(traveler?.node(withAction: "a1")?.label == "Save traveller")
    }

    /// Every surface Rust's golden files hold (cmux-tui `cmux-ui-surfaces/tests/golden`) reads here, with
    /// no node this build does not know.
    @Test func everyRustGoldenSurfaceDecodes() throws {
        let golden = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "cmux-tui/crates/cmux-ui-surfaces/tests/golden")
        let files = try FileManager.default.contentsOfDirectory(at: golden, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(files.count >= 10)
        var surfaces = 0
        for file in files {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
            for raw in value["surfaces"]?.arrayValue ?? [] {
                let surface = try #require(UISurface(json: raw), "\(file.lastPathComponent)")
                surfaces += 1
                func walk(_ node: UISurface.Node) {
                    #expect(node.nodeType != nil, "\(file.lastPathComponent): \(node.type)")
                    node.children?.forEach(walk)
                }
                if let root = surface.root { walk(root) }
            }
        }
        #expect(surfaces > 0)
    }

    @Test func anUnknownNodeAndABadFieldReadAsLittleAsPossible() throws {
        let error = try #require(UISurface(json: UISurfaceFixtures.json(UISurfaceFixtures.claimedError)))
        #expect(error.status == .error)
        #expect(error.source.verified == false)
        #expect(error.root?.children?.last?.type == "marquee")
        #expect(error.root?.children?.last?.nodeType == nil)
        // A field of the wrong JSON type is absent; the node and the surface stay.
        let odd = UISurfaceFixtures.json(#"{"schema":"cmux.ui-surface/1","surfaceId":"o","status":"later","root":{"id":"t","type":"text","text":42}}"#)
        let surface = try #require(UISurface(json: odd))
        #expect(surface.status == .ready)
        #expect(surface.root?.type == "text")
        #expect(surface.root?.text == nil)
        // Another schema is no surface.
        #expect(UISurface(json: UISurfaceFixtures.json(#"{"schema":"cmux.ui-surface/2","surfaceId":"o"}"#)) == nil)
    }

    @Test func theCallCarriesItInItsMetaItsRowFieldOrItsOutputMeta() throws {
        let surface = UISurfaceFixtures.json(UISurfaceFixtures.approvalCompact)
        let meta = JSONValue.object(["toolCallId": .string("c1"), "title": .string("mcp__cmux__ui_surface"),
                                     "_meta": .object(["acpmux": .object(["uiSurface": surface])])])
        let fromMeta = try meta.decoded(as: ACPToolCall.self)
        #expect(UISurface(fromMeta)?.surfaceId == "ap-compact")
        let row = JSONValue.object(["toolCallId": .string("c2"), "uiSurface": surface])
        #expect(UISurface(try row.decoded(as: ACPToolCall.self))?.surfaceId == "ap-compact")
        let output = ACPToolCall(id: "c3", title: "t", kind: .other,
                                 rawOutput: .object(["_meta": .object(["cmux": .object(["uiSurface": surface])])]))
        #expect(UISurface(output)?.surfaceId == "ap-compact")
        #expect(UISurface(ACPToolCall(id: "c4", title: "Read a.rs", kind: .read)) == nil)
        // An update replaces it whole.
        var call = fromMeta
        let update = try JSONValue.object(["toolCallId": .string("c1"), "_meta": .object(["cmux": .object(["uiSurface":
            UISurfaceFixtures.json(UISurfaceFixtures.approvalDanger)])])]).decoded(as: ACPToolCallUpdate.self)
        call.apply(update)
        #expect(UISurface(call)?.surfaceId == "ap-danger")
    }

    @Test func theCardTakesTheRowsPlaceOnlyWithTheFlagOn() {
        var turn = AgentTurn(id: "t1", prompt: "approve?", promptAt: Date(timeIntervalSince1970: 1_700_000_000))
        var call = ACPToolCall(id: "s1", title: "mcp__cmux__ui_surface", kind: .other, status: .completed)
        call.uiSurface = UISurfaceFixtures.json(UISurfaceFixtures.approvalFull)
        turn.items = [.tool(call)]
        func kinds(_ on: Bool) -> [ChatRow.Kind] {
            ChatTranscriptBuilder(diffs: ChatDiffCache()).build(turns: [turn], pendingPermission: nil, askOpen: false,
                                                                permissionBarHidden: false, uiSurfaces: on).flatMap(\.rows).map(\.kind)
        }
        #expect(kinds(true).contains { if case .uiSurface("s1", let surface) = $0 { surface.surfaceId == "ap-full" } else { false } })
        #expect(!kinds(true).contains { if case .tool = $0 { true } else { false } })
        #expect(kinds(false).contains { if case .tool(let drawn) = $0 { drawn.id == "s1" } else { false } })
        #expect(!kinds(false).contains { if case .uiSurface = $0 { true } else { false } })
    }

    @Test func pressesMakeTheMacsCalls() {
        let action = AgentClientIntent.uiSurfaceAction(surfaceId: "s", actionId: "a1", values: ["/traveler/name": .string("Ada")])
        #expect(action.uiSurfaceCall?.method == "_acpmux/ui_surface_action")
        #expect(action.uiSurfaceCall?.params["values"] == .object(["/traveler/name": .string("Ada")]))
        #expect(AgentClientIntent.uiSurfaceConfirm(surfaceId: "s", requestId: "r7").uiSurfaceCall?.method == "_acpmux/ui_surface_confirm")
        #expect(AgentClientIntent.uiSurfaceCancel(surfaceId: "s", requestId: "r7").uiSurfaceCall?.params["requestId"] == .string("r7"))
        #expect(AgentClientIntent.cancel.uiSurfaceCall == nil)
    }

    @Test func anEditDropsThePendingRequestAndConfirmSettlesIt() async throws {
        @MainActor final class Recorder: UISurfaceActions {
            var calls: [String] = []
            func action(surfaceId: String, actionId: String, values: [String: JSONValue]) async -> UISurface.Pending? {
                calls.append("action \(actionId) \(values["/traveler/name"]?.uiSurfaceText ?? "")")
                return UISurface.Pending(requestId: "r1", actionId: actionId, summary: "Send", sends: nil, target: "agent")
            }
            func confirm(surfaceId: String, requestId: String) { calls.append("confirm \(requestId)") }
            func cancel(surfaceId: String, requestId: String) { calls.append("cancel \(requestId)") }
        }
        let recorder = Recorder()
        let host = UISurfaceHost(actions: recorder)
        let surface = try #require(UISurface(json: UISurfaceFixtures.json(UISurfaceFixtures.travelerFormPending)))
        // The surface's own pending shows; an edit cancels it.
        #expect(host.pending(surface)?.requestId == "r7")
        host.set(surface, "/traveler/name", .string("Grace Hopper"))
        #expect(host.pending(surface) == nil)
        #expect(recorder.calls == ["cancel r7"])
        // A press sends the held values; the answer opens the strip; Confirm settles it.
        let save = try #require(surface.node(withAction: "a1")?.action)
        host.press(surface, save)
        while host.waiting.contains(surface.surfaceId) { await Task.yield() }
        #expect(recorder.calls.last == "action a1 Grace Hopper")
        let pending = try #require(host.pending(surface))
        host.confirm(surface, pending)
        #expect(recorder.calls.last == "confirm r1")
        #expect(host.pending(surface) == nil)
        #expect(host.confirmed[surface.surfaceId] == ["a1"])
    }
}
