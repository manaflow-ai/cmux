@testable import CmuxNextPhone
import CmuxNextWakeups
import Foundation
import Testing

/// p06-scheduler-342 (p06-scheduler.md rule 9, the hidden-view class): the phone tab follows its service through a
/// `VisibleObservation` on the tab's node, not a main-inherited ObservationStream task. While the tab is hidden, the
/// service's changes read and apply nothing (no picker rebuild, no frame capture); when it shows, it reads once and
/// applies once.
@MainActor @Suite(.serialized)
struct PhoneTabHiddenObservationTests {
    static let owner = "PhoneTabView.devices"

    @Test func aHiddenTabAppliesNothingAndShowingItAppliesOnce() async throws {
        let work = MainWorkScheduler.testing(ledger: WakeupLedger()) { _ in nil }
        let runner = FakePhoneRunner()
        runner.answer(["simctl", "list"], PhoneCommandResult(status: 0, stdout: try fixture("simctl-list")))
        runner.answer(["devicectl", "list"], PhoneCommandResult(status: 0, stdout: try fixture("devicectl-list")))
        let backend = XcodePhoneBackend(runner: runner)
        let phones = PhoneService(backend: backend, recorder: PhoneRecorder(backend: backend, root: temporaryFolder(), makeID: { "rec" }),
                                  scratch: temporaryFolder())
        let node = VisibilityNode(root: "test.phone.tab", own: .hidden)
        let view = PhoneTabView(service: phones, device: nil, node: node, mainWork: work)
        defer { view.close() }

        // The device list and a sent input both change what the tab follows.
        try await phones.reload()
        let phone = try await phones.defaultDevice()
        try await phones.send(.pasteboard("x"), to: phone.id)
        let hidden = try Self.entry(work)
        #expect(hidden.evaluations == 0, "a hidden phone tab read its service")
        #expect(hidden.applies == 0, "a hidden phone tab applied its service's changes")

        node.set(.visible)
        let shown = try Self.entry(work)
        #expect(shown.showRereads == 1, "showing the tab did not read its service once")
        #expect(shown.applies == 1, "showing the tab applied \(shown.applies) times (want 1)")
    }

    static func entry(_ work: MainWorkScheduler) throws -> ObservationLedger.Entry {
        try #require(work.observations.snapshot(matching: owner).first { $0.owner == owner }, "no observation named \(owner)")
    }
}
