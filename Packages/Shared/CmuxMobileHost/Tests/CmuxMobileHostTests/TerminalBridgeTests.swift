import CmuxLinkTesting
import CmuxMobileHost
import CmuxMobileWire
import CmuxTerminalStream
import Foundation
import Testing

@Suite("terminal channel bridge")
struct TerminalBridgeTests {
    func attached(_ h: PhoneHarness, window: UInt32 = 262_144, budget: Int? = nil) async throws -> (MobileChannel, FakeAttachment) {
        try await h.hello()
        let (channel, opened) = try await h.open(.terminal, id: 3, params: PhoneHarness.terminalParams(), window: window,
                                                 budget: budget, priority: .render)
        #expect(opened["t"] == "channel.opened")
        #expect(opened["params"]?["generation"] == .int(7))
        #expect(opened["params"]?["snapshot_version"] == .int(1))
        let attachment = try await within { try #require(await h.daemon.attachments.next()) }
        return (channel, attachment)
    }

    static func ready(offset: UInt64, bytes: Int = 64) -> TerminalFrame {
        TerminalFrame(kind: .snapshotReady, generation: 7, offset: offset, snapshotVersion: 1, payload: Data(repeating: 0x47, count: bytes))
    }

    @Test func attachForwardsViewerParamsAndSnapshotGoesOutAsKeyframe() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        let (channel, attachment) = try await attached(h)
        #expect(attachment.request.terminal == "term_x1")
        #expect(attachment.request.viewer.install == PhoneHarness.install)
        #expect(attachment.request.snapshotVersions == [1])
        attachment.emit(.frame(Self.ready(offset: 100)))
        attachment.emit(.frame(TerminalFrame(kind: .bytes, generation: 7, offset: 105, payload: Data("hello".utf8))))
        attachment.emit(.title("vim", cwd: "/src"))
        guard case .binary(let first, let flags) = try await PhoneHarness.next(channel) else { Issue.record("no frame"); return }
        #expect(flags.contains(.keyframe))
        #expect(try TerminalFrame(decoding: first).kind == .snapshotReady)
        guard case .binary(let second, let secondFlags) = try await PhoneHarness.next(channel) else { Issue.record("no bytes"); return }
        #expect(!secondFlags.contains(.keyframe))
        #expect(try TerminalFrame(decoding: second).payload == Data("hello".utf8))
        let title = try await PhoneHarness.nextJSON(channel)
        #expect(title["t"] == "terminal.title")
        #expect(title["cwd"] == "/src")
    }

    @Test func inputViewportPresenceAndSnapshotRequestsReachTheSessionHost() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        let (channel, attachment) = try await attached(h)
        try await channel.send(binary: TerminalInput(kind: .bytes, data: Data("ls\r".utf8)).encoded)
        try await channel.send(message: ChannelMessage(name: "terminal.viewport", body: ["viewport": ["cols": 98, "rows": 18]]))
        try await channel.send(message: ChannelMessage(name: "terminal.presence", body: ["visible": false, "counts": true]))
        try await channel.send(message: ChannelMessage(name: "terminal.snapshot_request",
                                                       body: ["terminal": "term_x1", "reason": "digest_mismatch", "have": .null, "request_id": "sr-1"]))
        var seen: [String] = []
        for _ in 0..<4 { seen.append(try await within { try #require(await attachment.recorded.next()) }) }
        #expect(seen == ["input", "viewport", "presence", "snapshot:digest_mismatch"])
        #expect(await attachment.inputs == [TerminalInput(kind: .bytes, data: Data("ls\r".utf8))])
        #expect(await attachment.viewports == [TerminalViewport(cols: 98, rows: 18)])
    }

    @Test func terminalsOutsideThisHostsTreeAreRefused() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let (_, refused) = try await h.open(.terminal, id: 3, params: PhoneHarness.terminalParams("term_zz9"))
        #expect(refused["t"] == "channel.refused")
        #expect(refused["code"] == "terminal.not_found")
    }

    @Test func aSlowViewerCostsOneSnapshotNotADisconnect() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        // A 4 KiB link budget and window: the phone reads nothing while the host floods.
        let (channel, attachment) = try await attached(h, window: 4096, budget: 4096)
        for index in 0..<40 {
            attachment.emit(.frame(TerminalFrame(kind: .bytes, generation: 7, offset: UInt64(index * 1000),
                                                 payload: Data(repeating: 0x61, count: 1000))))
        }
        let request = try await within { try #require(await attachment.recorded.next()) }
        #expect(request == "snapshot:gap")
        attachment.emit(.frame(Self.ready(offset: 50_000)))
        // Drain: the viewer eventually gets the READY as a keyframe and is still attached.
        let sawKeyframe = try await within { () -> Bool in
            while true {
                switch await channel.receive() {
                case .binary(let payload, let flags) where flags.contains(.keyframe):
                    return (try? TerminalFrame(decoding: payload).offset) == 50_000
                case .closed: return false
                default: continue
                }
            }
        }
        #expect(sawKeyframe)
        #expect(await attachment.detached == false)
    }

    @Test func exitAndCloseEndTheChannelWithTheOwnersWord() async throws {
        let h = try await PhoneHarness()
        defer { Task { await h.shutdown() } }
        let (channel, attachment) = try await attached(h)
        attachment.emit(.exited(code: 0, signal: nil))
        attachment.emit(.closed)
        let exited = try await PhoneHarness.nextJSON(channel)
        #expect(exited["t"] == "terminal.exited")
        #expect(exited["code"] == .int(0))
        let closed = try await PhoneHarness.nextJSON(channel)
        #expect(closed["t"] == "channel.closed")
        #expect(closed["code"] == "terminal.exited")
    }
}

extension JSONValue: @retroactive ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}
