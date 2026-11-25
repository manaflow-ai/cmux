import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// PROTOCOL.md "When no path works": a WireGuard dial that found no way to the
/// Mac (UDP, TURN and cmux's relay all failed) fails with `network_blocked` and
/// what each way did. Once the link has been down for the quiet bound, the
/// person reads what blocks it and the one thing to do, never nothing or a bare
/// "Offline", while the quiet retries go on beneath it.
@Suite struct NetworkBlockTests {
    /// The record as the Rust link sends it (`PathFailures::to_json`).
    private func error(_ json: String) -> LinkError { LinkError(code: LinkError.networkBlocked, message: json) }

    @Test func eachCauseSaysWhatToDoAndNamesTheHosts() {
        let blocked = NetworkBlock(json: #"{"udp":"blocked","turn":"no_allocation","turnHost":"turn.cloudflare.com","relay":"unreachable","relayHost":"mobile-api.cmux.dev","relayDetail":"ConnectionRefused"}"#)
        #expect(blocked.cause == .blocked)
        #expect(blocked.statusLine == "This network blocks cmux · Try another network")
        #expect(blocked.sentence.contains("turn.cloudflare.com"))
        #expect(blocked.sentence.contains("mobile-api.cmux.dev"))

        let inspected = NetworkBlock(json: #"{"udp":"blocked","turn":"no_allocation","relay":"tls_rejected","relayHost":"mobile-api.cmux.dev","relayDetail":"invalid peer certificate: UnknownIssuer"}"#)
        #expect(inspected.cause == .tlsInspection)
        #expect(inspected.statusLine == "This network's proxy blocks cmux · Ask IT to allow it")
        #expect(inspected.sentence.contains("TLS inspection"))

        let oldMac = NetworkBlock(json: #"{"udp":"blocked","turn":"none_offered","relay":"peer_cannot","relayHost":"mobile-api.cmux.dev"}"#)
        #expect(oldMac.cause == .macNeedsUpdate)
        #expect(oldMac.statusLine == "Update cmux on your Mac to connect on this network")

        let proxy = NetworkBlock(json: #"{"relay":"refused","relayStatus":403,"relayHost":"mobile-api.cmux.dev"}"#)
        #expect(proxy.cause == .refused(status: 403))
        #expect(proxy.sentence.contains("HTTP 403"))

        #expect(NetworkBlock(json: #"{"relay":"off","relayStatus":503}"#).cause == .relayPaused)
        // An unreadable record still reads as a block, never as a raw error.
        #expect(NetworkBlock(json: "not json").cause == .blocked)
    }

    @Test func theErrorReadsAsTheBlockNeverAsJSON() {
        let link = error(#"{"udp":"blocked","turn":"no_allocation","relay":"tls_rejected"}"#)
        #expect(link.displayReason == "this network's proxy blocks cmux")
        #expect(link.errorDescription?.contains("{") == false)
        #expect(link.errorDescription?.contains("TLS inspection") == true)
        #expect(LinkController.networkBlock(link)?.cause == .tlsInspection)
        #expect(LinkController.networkBlock(LinkError(code: "timeout", message: "")) == nil)
    }

    @Test func theLineStaysOnTheBlockThroughTheRetriesUntilADialWorks() {
        var machine = LinkMachine(transport: .wireGuard)
        _ = machine.handle(.target(LinkMachine.Target(macID: "m", name: "Studio", isOnline: true)))
        // A dial on its own says nothing.
        #expect(machine.phase.statusLine(macName: "Studio", block: machine.networkBlock) == nil)
        let block = NetworkBlock(json: #"{"udp":"blocked","turn":"no_allocation","relay":"timeout"}"#)
        // A dial that found no path: the block, then its failure (a quiet retry).
        _ = machine.handle(.networkBlocked(generation: machine.generation, block))
        _ = machine.handle(.dialFailed(generation: machine.generation, reason: error("{}").displayReason))
        guard case .connecting = machine.phase else { Issue.record("expected the quiet retry, got \(machine.phase)"); return }
        #expect(machine.phase.statusLine(macName: "Studio", block: machine.networkBlock) == "This network blocks cmux · Try another network")
        // The retry fails the same way: waiting for the next one, still the block.
        _ = machine.handle(.networkBlocked(generation: machine.generation, block))
        _ = machine.handle(.dialFailed(generation: machine.generation, reason: error("{}").displayReason))
        guard case .waiting = machine.phase else { Issue.record("expected a scheduled retry, got \(machine.phase)"); return }
        #expect(machine.phase.statusLine(macName: "Studio", block: machine.networkBlock) == block.statusLine)
        #expect(machine.phase.diagnosticLine(macName: "Studio", block: machine.networkBlock) == block.sentence)
        // The scheduled retry starts: still the block, not nothing.
        _ = machine.handle(.retryDue(generation: machine.generation))
        #expect(machine.phase.statusLine(macName: "Studio", block: machine.networkBlock) == block.statusLine)
        // Another network: the dial works, and the block is gone.
        _ = machine.handle(.dialSucceeded(generation: machine.generation, path: .httpsRelay))
        #expect(machine.networkBlock == nil)
        #expect(machine.phase.statusLine(macName: "Studio", block: machine.networkBlock) == nil)
        #expect(machine.phase.diagnosticLine(macName: "Studio") == "Connected · WireGuard relay (cmux, HTTPS)")
    }

    /// Review of #53164: after moving to a good network, a later failure of
    /// another kind (the Mac went to sleep) must not still say the network
    /// blocks cmux.
    @Test func aLaterFailureOfAnotherKindClearsTheBlock() {
        var machine = LinkMachine(transport: .wireGuard)
        _ = machine.handle(.target(LinkMachine.Target(macID: "m", name: "Studio", isOnline: true)))
        let block = NetworkBlock(json: #"{"udp":"blocked","turn":"no_allocation","relay":"timeout"}"#)
        _ = machine.handle(.networkBlocked(generation: machine.generation, block))
        _ = machine.handle(.dialFailed(generation: machine.generation, reason: "this network blocks cmux"))
        #expect(machine.networkBlock == block)
        // The quiet retry fails with a plain timeout: no networkBlocked before it.
        _ = machine.handle(.dialFailed(generation: machine.generation, reason: LinkError.timeoutReason))
        #expect(machine.networkBlock == nil)
        #expect(machine.phase.statusLine(macName: "Studio", block: machine.networkBlock) == nil)
    }

    @Test func anotherMacOrTransportForgetsTheBlock() {
        var machine = LinkMachine(transport: .wireGuard)
        _ = machine.handle(.target(LinkMachine.Target(macID: "m", name: "Studio", isOnline: true)))
        _ = machine.handle(.networkBlocked(generation: machine.generation, NetworkBlock()))
        #expect(machine.networkBlock != nil)
        _ = machine.handle(.target(LinkMachine.Target(macID: "m2", name: "Mini", isOnline: true)))
        #expect(machine.networkBlock == nil)
        _ = machine.handle(.networkBlocked(generation: machine.generation, NetworkBlock()))
        _ = machine.handle(.transport(.webRTC))
        #expect(machine.networkBlock == nil)
        // A late block of an abandoned dial is ignored.
        _ = machine.handle(.networkBlocked(generation: machine.generation - 1, NetworkBlock()))
        #expect(machine.networkBlock == nil)
    }
}
