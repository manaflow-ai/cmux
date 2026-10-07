@testable import CmuxNextDaemon
import Foundation
import Testing

/// `terminal-resources` (capability `terminal-resources-v1`): the request
/// names only the surfaces a card needs, and the reply decodes the host,
/// the shell and its descendants.
@Suite struct TerminalResourcesTests {
    @Test func encodesOnlyTheRequestedSurfaces() throws {
        let data = try WireCoding.encodeRequest(TerminalResourcesRequest(surfaces: [SurfaceID(rawValue: 3), SurfaceID(rawValue: 9)]), id: 1)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["cmd"] as? String == "terminal-resources")
        #expect(object["surfaces"] as? [Int] == [3, 9])

        let all = try WireCoding.encodeRequest(TerminalResourcesRequest(surfaces: nil), id: 2)
        let allObject = try #require(try JSONSerialization.jsonObject(with: all) as? [String: Any])
        #expect(allObject["surfaces"] == nil)
    }

    @Test func decodesTheDaemonReply() throws {
        let line = Data(#"""
        {"ok":true,"data":{"sampled_at_ns":123456789,"terminals":[{"surface":3,"terminal_id":"t1","pid":501,
        "host":{"pid":500,"cpu_ns":1000,"memory_bytes":4096},
        "processes":[{"pid":501,"ppid":500,"name":"zsh","cpu_ns":2000,"memory_bytes":8192},
        {"pid":777,"ppid":501,"name":"sleep","cpu_ns":10,"memory_bytes":1024}],"truncated":false},
        {"surface":4,"terminal_id":null,"pid":null,"host":null,"processes":[]}],"missing":[99]}}
        """#.utf8)
        let reply = try WireCoding.decodeResponse(TerminalResourcesRequest.Response.self, from: line)
        #expect(reply.sampledAtNanos == 123_456_789)
        #expect(reply.missing == [SurfaceID(rawValue: 99)])
        let first = try #require(reply.terminals.first)
        #expect(first.surface == SurfaceID(rawValue: 3))
        #expect(first.host == TerminalResourcesRequest.Process(pid: 500, cpuNanos: 1000, memoryBytes: 4096))
        #expect(first.processes.map(\.pid) == [501, 777])
        #expect(first.processes.first?.name == "zsh")
        #expect(reply.terminals[1].pid == nil)
        #expect(reply.terminals[1].host == nil)
    }
}
