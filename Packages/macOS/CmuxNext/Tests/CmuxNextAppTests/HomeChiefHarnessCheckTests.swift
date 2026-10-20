import AppKit
import CmuxNextHome
@testable import CmuxNextHomeEngine
import Testing

/// The Chief editor (Home and Settings > Agents > Chiefs) saves a new backend only after its
/// check (`_acpmux/harness/doctor`, one real hello turn) passed (docs/chiefs-create-byo-backend.md).
/// The Chief Settings popover set the harness straight away, so a harness that could not answer
/// became the Chief's brain. Now a new harness on this Mac's brain is checked first.
@MainActor @Suite struct HomeChiefHarnessCheckTests {
    static func view(_ writes: AsyncStream<[String: String?]>.Continuation, checked: @escaping @MainActor (String) async -> Bool,
                     local: Bool = true) async -> HomeChiefSettingsView {
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: CheckedChief(writes: writes, isLocal: local))
        view.checkHarness = checked
        await view.refresh().value
        return view
    }

    @Test func aHarnessThatFailsItsCheckIsNotSet() async {
        let (writes, continuation) = AsyncStream.makeStream(of: [String: String?].self)
        var checked: [String] = []
        let view = await Self.view(continuation, checked: { checked.append($0); return false })
        await view.pickHarness(ChiefBackend.codex.id).value
        continuation.finish()
        var sent: [[String: String?]] = []
        for await write in writes { sent.append(write) }
        #expect(checked == [ChiefBackend.codex.id])
        #expect(sent.isEmpty)
        #expect(view.harness.selectedItem?.representedObject as? String == ChiefBackend.claude.id)
        #expect(!view.failure.isHidden)
        #expect(view.harness.isEnabled)
    }

    @Test func aHarnessThatPassesItsCheckIsSet() async {
        let (writes, continuation) = AsyncStream.makeStream(of: [String: String?].self)
        let view = await Self.view(continuation, checked: { _ in true })
        await view.pickHarness(ChiefBackend.codex.id).value
        continuation.finish()
        var sent: [[String: String?]] = []
        for await write in writes { sent.append(write) }
        #expect(sent.map { $0["harness"] } == [.some(ChiefBackend.codex.id)])
        #expect(view.failure.isHidden)
    }

    /// While the check runs the pickers stay off, a refresh (a new message, a turn's end) too,
    /// and a newer pick drops the earlier check's answer.
    @Test func aCheckInFlightKeepsThePickersOffAndANewerPickWins() async {
        let (writes, continuation) = AsyncStream.makeStream(of: [String: String?].self)
        let gate = CheckGate()
        let view = await Self.view(continuation, checked: { _ in await withCheckedContinuation { gate.waiting.append($0) } })
        let first = view.pickHarness(ChiefBackend.codex.id)
        #expect(!view.harness.isEnabled)
        await view.refresh().value
        #expect(!view.harness.isEnabled)
        let second = view.pickHarness(ChiefBackend.unii.id)
        for _ in 0..<200 where gate.waiting.count < 2 { await Task.yield() }
        #expect(gate.waiting.count == 2)
        for check in gate.waiting { check.resume(returning: true) }
        await first.value
        await second.value
        continuation.finish()
        var sent: [String?] = []
        for await write in writes { sent.append(write["harness"] ?? nil) }
        #expect(sent == [ChiefBackend.unii.id])
        #expect(view.harness.isEnabled)
    }

    /// A route harness comes from the Chief's own acpmux config, which the app's check does not see.
    @Test func aRouteHarnessIsNotChecked() async {
        let (writes, continuation) = AsyncStream.makeStream(of: [String: String?].self)
        var checked = 0
        let view = await Self.view(continuation, checked: { _ in checked += 1; return false })
        await view.pickHarness("claude-cr").value
        continuation.finish()
        var sent = 0
        for await _ in writes { sent += 1 }
        #expect(checked == 0)
        #expect(sent == 1)
    }

    /// A paired server's brain runs its own acpmux: this Mac's check says nothing about it.
    @Test func aCloudChiefIsNotCheckedOnThisMac() async {
        let (writes, continuation) = AsyncStream.makeStream(of: [String: String?].self)
        var checked = 0
        let view = await Self.view(continuation, checked: { _ in checked += 1; return false }, local: false)
        await view.pickHarness(ChiefBackend.codex.id).value
        continuation.finish()
        var sent = 0
        for await _ in writes { sent += 1 }
        #expect(checked == 0)
        #expect(sent == 1)
    }
}

/// Checks that wait until the test answers them.
@MainActor private final class CheckGate {
    var waiting: [CheckedContinuation<Bool, Never>] = []
}

/// A brain on Claude that records each write.
private struct CheckedChief: HomeChiefEngineSource {
    let writes: AsyncStream<[String: String?]>.Continuation
    let isLocal: Bool
    var place: String? { isLocal ? nil : "server" }

    func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        HomeChiefSnapshot(harness: ChiefBackend.claude.id, model: nil, effort: nil, avatar: nil, turns: [])
    }

    func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        writes.yield(fields)
        var snapshot = try await read()
        if let harness = fields["harness"] { snapshot.harness = harness }
        return snapshot
    }
}
