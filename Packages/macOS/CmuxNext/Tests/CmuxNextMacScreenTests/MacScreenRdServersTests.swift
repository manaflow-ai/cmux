import CmuxNextCompat
import CmuxScreenKit
import Foundation
@testable import CmuxNextMacScreen
import Testing

/// The hub's ICE servers as the cmux.rd link takes them: the same relays, in the same order,
/// as `rd_doc::servers` in cmux-hub-host (its test `ice_servers_keep_udp_relays_first_then_tcp_and_tls`
/// and `setup_line_keeps_turn_udp_and_carries_tcp_and_tls_relays_beside_it` use these URLs).
@Suite struct MacScreenRdServersTests {
    @Test func udpRelaysGoInTurnAndTcpThenTlsInTurnStream() {
        let servers = MacScreenRdServers([
            ICEServerConfig(urls: ["turns:turn.example:443?transport=tcp", "stun:stun.example",
                                   "turn:turn.example:443?transport=tcp", "turn:turn.example:3478?transport=udp",
                                   "turns:tls.example"],
                            username: "u", credential: "p"),
            ICEServerConfig(urls: ["stun:stun.example:3478"]),
            ICEServerConfig(urls: ["turn:nocreds.example"]),
        ])
        let relay = { (addr: String, transport: MacScreenRdServers.Transport) in
            MacScreenRdServers.Turn(addr: addr, username: "u", password: "p", transport: transport)
        }
        #expect(servers.stun == ["stun.example:3478"])
        #expect(servers.turn == [relay("turn.example:3478", .udp)])
        #expect(servers.turnStream == [relay("turn.example:443", .tcp), relay("turn.example:443", .tls),
                                       relay("tls.example:5349", .tls)])
    }

    @Test func aUdpRelayEncodesAsBeforeAndTheOthersNameTheirTransport() throws {
        let servers = MacScreenRdServers([
            ICEServerConfig(urls: ["turns:t.example:443?transport=tcp", "turn:t.example:3478",
                                   "turn:t.example:80?TRANSPORT=TCP"],
                            username: "u", credential: "p"),
        ])
        let json = { (turn: [MacScreenRdServers.Turn]) throws -> NSArray? in
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(turn)) as? NSArray
        }
        #expect(try json(servers.turn) == [["addr": "t.example:3478", "username": "u", "password": "p"]] as NSArray)
        #expect(try json(servers.turnStream) == [
            ["addr": "t.example:80", "username": "u", "password": "p", "transport": "tcp"],
            ["addr": "t.example:443", "username": "u", "password": "p", "transport": "tls"],
        ] as NSArray)
    }
}
