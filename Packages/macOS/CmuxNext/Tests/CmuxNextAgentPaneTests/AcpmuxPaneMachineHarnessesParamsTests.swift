import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A new chat that will start on another of the person's machines asks that machine for its agents
/// (Austin, 2026-11-12; webviews machineHarnesses.ts): the pane sends `_acpmux/harnesses` with
/// `_meta.acpmux.peer`, which acpmux forwards to that peer (cmux-tui acpmux server/requests.rs,
/// local and app connections only, no caller params sent on). The params rule lets exactly that
/// through: one non-empty peer name under `_meta.acpmux`, nothing else under `_meta`.
@Suite
struct AcpmuxPaneMachineHarnessesParamsTests {
    private static func harnesses(_ params: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": 1, "method": "_acpmux/harnesses", "params": params]
    }

    @Test func aPeerReadPassesTheParamsRule() {
        let read = Self.harnesses(["_meta": ["acpmux": ["peer": "studio"]]])
        #expect(!AcpmuxPaneMethods.breaksParamsRule(read, modeFields: nil))
    }

    @Test func thisMacsReadsStillPass() {
        #expect(!AcpmuxPaneMethods.breaksParamsRule(Self.harnesses([:]), modeFields: nil))
        #expect(!AcpmuxPaneMethods.breaksParamsRule(Self.harnesses(["cwd": "/Users/you/src/cmux"]), modeFields: nil))
    }

    @Test func anythingElseUnderMetaIsRefused() {
        for meta: [String: Any] in [
            ["acpmux": ["peer": "studio", "harness": "claude"]],
            ["acpmux": ["harness": "claude"]],
            ["acpmux": ["peer": "studio"], "cmuxGesture": "ticket"],
            ["other": true],
            ["acpmux": "studio"],
        ] {
            #expect(AcpmuxPaneMethods.breaksParamsRule(Self.harnesses(["_meta": meta]), modeFields: nil), "\(meta)")
        }
    }

    @Test func aPeerMustBeANonEmptyName() {
        for peer: Any in ["", 7, ["studio"], NSNull()] {
            let read = Self.harnesses(["_meta": ["acpmux": ["peer": peer]]])
            #expect(AcpmuxPaneMethods.breaksParamsRule(read, modeFields: nil), "\(peer)")
        }
    }

    /// The relay filters no `_acpmux/harnesses` reply itself, so a peer's harness list (and its
    /// `peer` field) reaches the page as acpmux sends it.
    @Test func theRelayLeavesTheHarnessReplyWhole() {
        #expect(AcpmuxPaneMethods.replyShapes["_acpmux/harnesses"] == nil)
    }
}

/// The same read through the relay: it reaches acpmux with its peer, where it was refused before.
@Suite(.serialized)
@MainActor
struct AgentPaneMachineHarnessesRelayTests {
    @Test func aPeerReadReachesAcpmuxWithItsPeer() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [AgentPaneFrameKeysRelayTests.initialize(id: 0)]) == nil)
        _ = await inbox.frame(containing: #""id":0"#)

        let read = #"{"jsonrpc":"2.0","id":5,"method":"_acpmux/harnesses","params":{"_meta":{"acpmux":{"peer":"studio"}}}}"#
        let sent = await transport.send(connection: id, frames: [read])
        #expect(sent == nil, "the relay refused the peer read")
        // Waits for acpmux's answer only once the relay took the frame (a refusal has no answer to wait for).
        if sent == nil { _ = await inbox.frame(containing: #""id":5"#) }
        let reached = (server.peers.first?.frames ?? []).filter { $0.contains("_acpmux/harnesses") }
        #expect(reached.count == 1)
        #expect(reached.first?.contains(#""peer":"studio""#) == true, "\(reached)")

        let extra = #"{"jsonrpc":"2.0","id":6,"method":"_acpmux/harnesses","params":{"_meta":{"acpmux":{"peer":"studio","harness":"x"}}}}"#
        #expect(await transport.send(connection: id, frames: [extra]) == .intentInvalid)
    }
}
