import Foundation
import Testing
@testable import CmuxMobileWire

@Suite struct TunnelParamsTests {
    let fixtures = Fixtures()

    private func frames(_ file: String, _ message: String, phase: String = "request") throws -> [JSONValue] {
        try #require(fixtures.json("fixtures/\(file).json")["cases"]?.arrayValue)
            .filter { ($0["phase"]?.stringValue ?? "request") == phase && $0["message"]?.stringValue == message }
            .compactMap { $0["frame"] }
    }

    @Test func tcpForwardParamsRoundTrip() throws {
        let frame = try #require(frames("tunnel", "tcp.forward").first)
        #expect(frame["kind"]?.stringValue == ChannelKind.tcpForward.rawValue)
        let params = try #require(frame["params"])
        #expect(try params.decode(as: TcpForwardParams.self) == TcpForwardParams(port: 5173))
        let opened = try #require(frames("tunnel", "tcp.forward", phase: "opened").first?["params"])
        #expect(try opened.decode(as: TcpForwardOpenedParams.self) == TcpForwardOpenedParams(port: 5173, source: .detected))
        #expect(try JSONValue(encoding: TcpForwardOpenedParams(port: 5173, source: .detected)) == opened)
    }

    @Test func tunnelPortsResultRoundTrip() throws {
        let value = try #require(frames("tunnel", "tunnel.ports", phase: "result").first?["value"])
        let result = try value.decode(as: TunnelPortsResult.self)
        #expect(result.ports == [TunnelPort(port: 5173, source: .detected, workspace: "ws_a1", process: "node"),
                                 TunnelPort(port: 8080, source: .allowed)])
        #expect(try JSONValue(encoding: result) == value)
    }

    @Test func simulatorListRoundTrip() throws {
        let value = try #require(frames("simulator", "simulator.list", phase: "result").first?["value"])
        let result = try value.decode(as: SimulatorListResult.self)
        #expect(result.simulators.first?.state == .booted)
        #expect(try JSONValue(encoding: result) == value)
        let open = try #require(frames("simulator", "simulator").first)
        #expect(open["kind"]?.stringValue == ChannelKind.simulator.rawValue)
    }
}
