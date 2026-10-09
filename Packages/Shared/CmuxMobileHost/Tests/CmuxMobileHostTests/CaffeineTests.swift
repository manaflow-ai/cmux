import CmuxMobileHost
import CmuxMobileLink
import CmuxMobileWire
import Foundation
import Testing

@Suite("mobile caffeine")
struct CaffeineTests {
    @Test func statusReadAndIdempotentSetUseTheMacControl() async throws {
        let control = TestCaffeineControl()
        let h = try await PhoneHarness(caffeine: control)
        defer { Task { await h.shutdown() } }
        try await h.hello()
        let (rpc, _) = try await h.open(.rpc, id: 1)

        try await rpc.send(frame: .read(ReadFrame(id: 4, op: "caffeine.status", params: .object([:]))))
        let status = try await PhoneHarness.nextJSON(rpc)
        #expect(status["t"] == "read.result")
        #expect(status["value"]?["enabled"] == .bool(false))

        let op = OpFrame(op: "caffeine.set", params: .object(["enabled": .bool(true)]),
                         idempotencyKey: "caffeine-key-1")
        try await rpc.send(frame: .op(op))
        let result = try await PhoneHarness.nextJSON(rpc)
        #expect(result["t"] == "result")
        #expect(result["value"]?["enabled"] == .bool(true))
        _ = try await PhoneHarness.nextJSON(rpc)
        #expect(await control.value() == true)

        try await rpc.send(frame: .op(op))
        #expect(try await PhoneHarness.nextJSON(rpc)["replayed"] == true)
        _ = try await PhoneHarness.nextJSON(rpc)
        #expect(await control.setCount() == 1)
    }
}

private actor TestCaffeineControl: MobileCaffeineControl {
    private var enabled = false
    private var writes = 0

    func status() async -> Bool { enabled }

    func set(enabled: Bool) async throws {
        self.enabled = enabled
        writes += 1
    }

    func value() -> Bool { enabled }
    func setCount() -> Int { writes }
}
