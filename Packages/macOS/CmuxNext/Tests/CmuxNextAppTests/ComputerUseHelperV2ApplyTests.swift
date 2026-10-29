import Darwin
import Foundation
import Testing
@testable import CmuxNextComputerUse

/// `apply(enabled:)` awaits the helper's spawn: an apply that turns Computer Use off while
/// the spawn is in flight owns the state, whatever the spawn then does.
@MainActor
struct ComputerUseHelperV2ApplyTests {
    @Test func turningOffDuringASpawnThatFailsLeavesItOff() async throws {
        let directory = "/tmp/cmux-cua-apply-\(UUID().uuidString.prefix(8))/scope"
        defer { try? FileManager.default.removeItem(atPath: (directory as NSString).deletingLastPathComponent) }
        let spawner = GatedSpawner()
        let helper = ComputerUseHelperV2(directory: directory,
                                         helperApp: { URL(fileURLWithPath: "/nonexistent/cmux-cua-test.app") },
                                         spawner: spawner)
        let turningOn = Task { await helper.apply(enabled: true) }
        var calls = spawner.calls.makeAsyncIterator()
        try #require(await calls.next() != nil)

        await helper.apply(enabled: false)
        spawner.release.yield()
        await turningOn.value

        #expect(helper.state == .off)
    }
}

/// A spawner whose spawn waits until the test releases it, then fails.
private nonisolated final class GatedSpawner: ComputerUseHelperV2Spawning {
    struct Refused: Error {}

    /// One element per spawn call, when the spawn starts waiting.
    let calls: AsyncStream<Void>
    private let callsInput: AsyncStream<Void>.Continuation
    /// Ends the waiting spawn.
    let release: AsyncStream<Void>.Continuation
    private let releases: AsyncStream<Void>

    init() {
        (calls, callsInput) = AsyncStream.makeStream()
        (releases, release) = AsyncStream.makeStream()
    }

    func spawn(executable: URL, environment: [String: String], logPath: String) async throws -> ComputerUseHelperV2Child {
        callsInput.yield()
        for await _ in releases { break }
        throw Refused()
    }

    func terminate(_ pid: pid_t) {}
}
