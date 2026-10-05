import Foundation
import Testing
@testable import CmuxNextAgentPane

/// ad349 round 4. R1: a frame that redeems a gesture ticket carries no `_meta` key other than
/// `cmuxGesture`. R2: a set_mode or a "mode" set_config_option to a value that the daemon's table
/// does not list as asking also needs the host's native sheet (one at a time, only after the
/// gesture rule passed; Cancel refuses). Without the daemon's answer, every mode needs the sheet.
@MainActor
@Suite(.serialized) struct AgentPaneModeConfirmationTests {
    typealias Rig = AgentPaneGestureTicketTests.Rig

    /// A fake native sheet: records each ask, and answers at once or when the test says.
    final class Sheets {
        var asked: [String] = []
        var open = 0
        var maxOpen = 0
        var held: [@MainActor (Bool) -> Void] = []
        /// nil holds every answer until `answer(_:)`.
        var reply: Bool?

        init(on transport: AgentPaneTransport, reply: Bool?) {
            self.reply = reply
            transport.requestModeConfirmation = { [self] mode, answer in
                asked.append(mode)
                open += 1
                maxOpen = max(maxOpen, open)
                let done: @MainActor (Bool) -> Void = { [self] ok in open -= 1; answer(ok) }
                if let reply { done(reply) } else { held.append(done) }
            }
        }

        func answer(_ ok: Bool) { held.removeFirst()(ok) }
    }

    static func setMode(_ mode: String) -> [String: Any] { ["method": "session/set_mode", "params": ["modeId": mode]] }
    static func configMode(_ mode: String) -> [String: Any] {
        ["method": "session/set_config_option", "params": ["configId": "mode", "value": mode]]
    }

    /// A frame with `meta` as its whole `_meta`.
    func send(_ rig: Rig, _ method: String, _ params: [String: Any], meta: [String: Any]) async -> AgentPaneTransportError? {
        rig.nextID += 1
        var params = params
        params["_meta"] = meta
        let object: [String: Any] = ["jsonrpc": "2.0", "id": rig.nextID, "method": method, "params": params]
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        return await rig.transport.send(connection: rig.connection, frames: [text])
    }

    func daemonSaw(_ rig: Rig, _ needle: String) -> Bool {
        rig.server.peers.last?.frames.contains { $0.contains(needle) } == true
    }

    func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1000 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }

    // MARK: R1

    @Test func aRedeemingFrameWithOtherMetaIsRefusedAndSpendsItsTicket() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let params: [String: Any] = ["sessionId": "s", "modeId": "plan"]
        for extra in [["other": 1], ["cmuxGesture2": "x"], ["": true], ["progressToken": "p"]] as [[String: Any]] {
            let ticket = try #require(await rig.ticket(Self.setMode("plan")))
            var meta = extra
            meta["cmuxGesture"] = ticket
            #expect(await send(rig, "session/set_mode", params, meta: meta) == .intentInvalid, "\(extra)")
            // The refused frame spent the ticket: its own pick with a clean _meta no longer passes.
            #expect(await rig.send("session/set_mode", params, ticket: ticket) == .gestureRequired, "\(extra)")
        }
        #expect(!daemonSaw(rig, "session/set_mode"))
        // The control: a ticket alone in _meta passes, and the daemon never sees it.
        #expect(await rig.send("session/set_mode", params, ticket: await rig.ticket(Self.setMode("plan"))) == nil)
        #expect(await rig.server.wait { $0.last?.frames.contains { $0.contains("session/set_mode") } == true })
        #expect(!daemonSaw(rig, "cmuxGesture"))
    }

    // MARK: R2

    @Test func aTicketForANonAskingModeWithoutTheSheetIsRefused() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        // The pane has no sheet to show (no window): the host refuses.
        rig.model.onConfirmMode = nil
        let ticket = await rig.ticket(Self.setMode("bypassPermissions"))
        #expect(await rig.send("session/set_mode", ["sessionId": "s", "modeId": "bypassPermissions"], ticket: ticket) == .modeNotConfirmed)
        #expect(!daemonSaw(rig, "bypassPermissions"))
    }

    @Test func aConfirmedSheetLetsTheModePass() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let sheets = Sheets(on: rig.transport, reply: true)
        #expect(await rig.send("session/set_mode", ["sessionId": "s", "modeId": "bypassPermissions"],
                               ticket: await rig.ticket(Self.setMode("bypassPermissions"))) == nil)
        #expect(sheets.asked == ["bypassPermissions"])
        #expect(await rig.server.wait { $0.last?.frames.contains { $0.contains("bypassPermissions") } == true })
    }

    @Test func cancelRefusesTheMode() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let sheets = Sheets(on: rig.transport, reply: false)
        #expect(await rig.send("session/set_mode", ["sessionId": "s", "modeId": "acceptEdits"],
                               ticket: await rig.ticket(Self.setMode("acceptEdits"))) == .modeNotConfirmed)
        #expect(await rig.send("session/set_config_option", ["sessionId": "s", "configId": "mode", "value": "dontAsk"],
                               ticket: await rig.ticket(Self.configMode("dontAsk"))) == .modeNotConfirmed)
        #expect(sheets.asked == ["acceptEdits", "dontAsk"])
        #expect(!daemonSaw(rig, "acceptEdits"))
        #expect(!daemonSaw(rig, "dontAsk"))
    }

    @Test func anAskingModeNeedsNoSheet() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let sheets = Sheets(on: rig.transport, reply: false)
        #expect(await rig.send("session/set_mode", ["sessionId": "s", "modeId": "plan"], ticket: await rig.ticket(Self.setMode("plan"))) == nil)
        #expect(await rig.send("session/set_config_option", ["sessionId": "s", "configId": "mode", "value": "default"],
                               ticket: await rig.ticket(Self.configMode("default"))) == nil)
        // An effort or model pick is not a mode: it keeps the ticket rule alone.
        #expect(await rig.send("session/set_config_option", ["sessionId": "s", "configId": "effort", "value": "high"],
                               ticket: await rig.ticket(["method": "session/set_config_option", "params": ["configId": "effort", "value": "high"]])) == nil)
        #expect(sheets.asked.isEmpty)
    }

    @Test func theSheetComesOnlyAfterTheGestureRule() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let sheets = Sheets(on: rig.transport, reply: true)
        // No ticket and no live gesture: refused before any sheet.
        #expect(await rig.send("session/set_mode", ["sessionId": "s", "modeId": "bypassPermissions"], ticket: nil) == .gestureRequired)
        // A ticket for another pick.
        #expect(await rig.send("session/set_mode", ["sessionId": "s", "modeId": "bypassPermissions"],
                               ticket: await rig.ticket(Self.setMode("plan"))) == .gestureRequired)
        #expect(sheets.asked.isEmpty)
    }

    @Test func withoutTheDaemonsTableEveryModeNeedsTheSheet() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        rig.transport.modeAsks = { _, _ in nil }
        let sheets = Sheets(on: rig.transport, reply: false)
        #expect(await rig.send("session/set_mode", ["sessionId": "s", "modeId": "plan"], ticket: await rig.ticket(Self.setMode("plan")))
            == .modeNotConfirmed)
        #expect(sheets.asked == ["plan"])
    }

    @Test func everyPaneSharesTheAppWideGate() {
        let a = AgentPaneModel(host: MockAgentPaneHost())
        let b = AgentPaneModel(host: MockAgentPaneHost())
        #expect(a.transport.confirmationGate === AgentPaneConfirmationGate.shared)
        #expect(b.transport.confirmationGate === a.transport.confirmationGate)
    }

    /// Two panes (two transports, as in two windows) on one gate: while pane A's sheet is open, pane
    /// B's mode frame is refused and opens no sheet; after A's answer, B can ask.
    @Test func aSecondPaneCannotOpenASecondSheet() async throws {
        let gate = AgentPaneConfirmationGate()
        let a = Rig()
        let b = Rig()
        try await a.start()
        try await b.start()
        defer { a.server.stop(); b.server.stop() }
        a.transport.confirmationGate = gate
        b.transport.confirmationGate = gate
        let sheetsA = Sheets(on: a.transport, reply: nil)
        let sheetsB = Sheets(on: b.transport, reply: true)
        let ticketA = await a.ticket(Self.setMode("bypassPermissions"))
        let first = Task { await a.send("session/set_mode", ["sessionId": "s", "modeId": "bypassPermissions"], ticket: ticketA) }
        #expect(await eventually { sheetsA.asked.count == 1 })
        #expect(gate.isOpen)
        #expect(await b.send("session/set_mode", ["sessionId": "s", "modeId": "acceptEdits"],
                             ticket: await b.ticket(Self.setMode("acceptEdits"))) == .modeNotConfirmed)
        #expect(sheetsB.asked.isEmpty, "no second sheet")
        #expect(!daemonSaw(b, "acceptEdits"))
        sheetsA.answer(true)
        #expect(await first.value == nil)
        #expect(!gate.isOpen)
        #expect(await b.send("session/set_mode", ["sessionId": "s", "modeId": "acceptEdits"],
                             ticket: await b.ticket(Self.setMode("acceptEdits"))) == nil)
        #expect(sheetsB.asked == ["acceptEdits"])
    }

    @Test func oneSheetAtATime() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let sheets = Sheets(on: rig.transport, reply: nil)
        let modeTicket = await rig.ticket(Self.setMode("bypassPermissions"))
        let configTicket = await rig.ticket(Self.configMode("acceptEdits"))
        let first = Task { await rig.send("session/set_mode", ["sessionId": "s", "modeId": "bypassPermissions"], ticket: modeTicket) }
        let second = Task {
            await rig.send("session/set_config_option", ["sessionId": "s", "configId": "mode", "value": "acceptEdits"], ticket: configTicket)
        }
        #expect(await eventually { sheets.asked.count == 1 })
        sheets.answer(true)
        #expect(await eventually { sheets.asked.count == 2 })
        sheets.answer(false)
        #expect(await first.value == nil)
        #expect(await second.value == .modeNotConfirmed)
        #expect(sheets.maxOpen == 1)
    }
}
