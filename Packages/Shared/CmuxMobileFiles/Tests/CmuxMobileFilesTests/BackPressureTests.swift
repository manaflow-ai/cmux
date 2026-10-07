import CmuxLink
import CmuxMobileFiles
import CmuxMobileHost
import CmuxMobileLink
import CmuxMobileWire
import Foundation
import Testing

/// A Mac upload handler that stops reading after `consumeFirst` chunks
/// until released, so the phone's sender must stall on link credit.
actor StallingUploadHandler: MobileChannelHandler {
    let consumeFirst: Int
    private(set) var consumedBytes = 0
    private var stalled: CheckedContinuation<Void, Never>?
    private var isStalled = false
    private var release: CheckedContinuation<Void, Never>?

    init(consumeFirst: Int) {
        self.consumeFirst = consumeFirst
    }

    func waitUntilStalled() async {
        if isStalled { return }
        await withCheckedContinuation { stalled = $0 }
    }

    func resume() {
        release?.resume()
        release = nil
    }

    func serve(_ channel: MobileChannel, open: ChannelOpenFrame, principal: MobileDevicePrincipal,
               gate: MobileSessionGate) async {
        guard let params = try? JSONValue.object(open.params).decode(as: FilesUploadParams.self) else { return }
        try? await channel.send(frame: .channelOpened(ChannelOpenedFrame(channel: open.channel, window: 65536,
                                                                         params: ["upload": .string("up_test"), "offset": .int(0)],
                                                                         resumed: false)))
        var chunks = 0
        while true {
            if chunks == consumeFirst {
                isStalled = true
                stalled?.resume()
                stalled = nil
                await withCheckedContinuation { release = $0 }
            }
            switch await channel.receive() {
            case .binary(let payload, _):
                chunks += 1
                consumedBytes += payload.count - 8
            case .json:
                let done = FilesUploadDone(upload: "up_test", path: "/stalled/\(params.name)", size: params.size)
                try? await channel.send(message: done.message)
                await channel.finish()
                return
            case .gap: continue
            case .closed: return
            }
        }
    }
}

final class MaxBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func record(_ v: UInt64) { lock.withLock { value = max(value, v) } }
    var current: UInt64 { lock.withLock { value } }
}

@Suite("Back-pressure")
struct BackPressureTests {
    @Test func aStalledMacBoundsWhatThePhoneSends() async throws {
        let handler = StallingUploadHandler(consumeFirst: 4)
        let w = try await FilesWorld(uploadHandler: handler)
        defer { Task { await w.shutdown() } }
        let chunk = 16 * 1024
        let budget = 64 * 1024
        let client = MobileFileClient(session: try await w.connect(), chunkBytes: chunk, budgetBytes: budget)
        let data = FilesWorld.bytes(1_000_000)
        let source = try w.phoneFile("bp.bin", data)
        let sent = MaxBox()
        let upload = Task {
            try await client.upload(source, name: "bp.bin", mime: "application/octet-stream", sha256: FilesWorld.sha256(data),
                                    dest: FilesUploadDestination(kind: .composer)) { completed, _ in sent.record(completed) }
        }
        try await within { await handler.waitUntilStalled() }
        // Give the sender time to run into the credit wall; it must not get past it.
        try await Task.sleep(for: .milliseconds(300))
        let consumed = UInt64(await handler.consumedBytes)
        #expect(consumed == UInt64(4 * chunk))
        #expect(sent.current <= consumed + UInt64(budget + chunk), "sent \(sent.current) with \(consumed) consumed")
        #expect(sent.current < UInt64(data.count))
        await handler.resume()
        let done = try await within { try await upload.value }
        #expect(done.path == "/stalled/bp.bin")
        #expect(sent.current == UInt64(data.count))
    }
}
