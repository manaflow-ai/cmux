@testable import CmuxNextApp
import AppKit
import CmuxNextAgentActivity
import CmuxNextOnboarding
import Foundation
import Observation
import Synchronization
import Testing

/// Computer Use Setup reads the helper's real grants: unknown while Computer
/// Use is off or locked, read once the helper runs, read again when the app
/// becomes active (the person comes back from System Settings) or macOS
/// posts an Accessibility trust change, and never on a timer.
@MainActor
@Suite struct ComputerUseSetupTests {
    /// The fake helper's reads, shared with the read closure off the main actor.
    final class Reads: Sendable {
        let count = Mutex(0)
        let answers = Mutex<[ComputerUseSetup.Read]>([])
    }

    @MainActor @Observable final class Fixture {
        var policy = false
        var enabled = false
        var helper: ComputerUseHelperDaemon.State = .off
        @ObservationIgnored let reads = Reads()
        @ObservationIgnored var opened: [URL] = []
        @ObservationIgnored var enables = 0

        var inputs: ComputerUseSetup.Inputs { .init(disabledByPolicy: policy, enabled: enabled, helper: helper) }

        /// The next read's answer; the last one repeats.
        func answer(_ next: ComputerUseSetup.Read...) { reads.answers.withLock { $0 = next } }
        var readCount: Int { reads.count.withLock { $0 } }
    }

    static func make(_ fixture: Fixture, clock: any Clock<Duration> = ContinuousClock(),
                     notifications: NotificationCenter = NotificationCenter(),
                     distributed: NotificationCenter = NotificationCenter()) -> ComputerUseSetup {
        let reads = fixture.reads
        let setup = ComputerUseSetup(
            inputs: { fixture.inputs },
            configuration: { .init(socketPath: "/nonexistent/cua.sock", machineName: "") },
            read: { _ in
                reads.count.withLock { $0 += 1 }
                return reads.answers.withLock { list in list.count > 1 ? list.removeFirst() : (list.first ?? .noAnswer) }
            },
            resolveHelper: { running in running ?? URL(fileURLWithPath: "/Applications/cmux NIGHTLY.app/Contents/Library/cmux Computer Use.app") },
            openURL: { fixture.opened.append($0) },
            enableSetting: { fixture.enables += 1; fixture.enabled = true },
            notifications: notifications, distributed: distributed, clock: clock)
        setup.start()
        return setup
    }

    static func waitUntil(_ what: String? = nil, sourceLocation: SourceLocation = #_sourceLocation,
                          _ condition: () -> Bool) async throws {
        try await waitForCondition(what, timeout: .seconds(5), sourceLocation: sourceLocation, condition)
    }

    @Test func offTheGrantsAreUnknownAndNothingIsRead() async throws {
        let fixture = Fixture()
        let setup = Self.make(fixture)
        try await Self.waitUntil { setup.helperAppURL != nil }
        #expect(setup.phase == .off)
        #expect(setup.stepPermissions.isOff, "off is not reported as not granted")
        #expect(fixture.readCount == 0)
    }

    @Test func aPolicyLockWinsOverTheSetting() async throws {
        let fixture = Fixture()
        fixture.policy = true
        fixture.enabled = true
        let setup = Self.make(fixture)
        try await Self.waitUntil { setup.phase == .disabledByPolicy }
        #expect(fixture.readCount == 0)
    }

    @Test func aRunningHelperGivesItsGrantsAndTheirChangesFollowActivation() async throws {
        let fixture = Fixture()
        fixture.enabled = true
        fixture.helper = .running(42)
        fixture.answer(.answered(ComputerUsePermissions(accessibility: true, screenRecording: false), helper: nil))
        let notifications = NotificationCenter()
        let setup = Self.make(fixture, notifications: notifications)
        try await Self.waitUntil { setup.phase == .ready }
        #expect(setup.permissions == ComputerUsePermissions(accessibility: true, screenRecording: false))
        #expect(fixture.readCount == 1, "one read, no timer")

        // The person grants Screen Recording in System Settings and comes back.
        fixture.answer(.answered(ComputerUsePermissions(accessibility: true, screenRecording: true), helper: nil))
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await Self.waitUntil { setup.permissions.screenRecording }
        #expect(fixture.readCount == 2)
    }

    @Test func anAccessibilityTrustChangeReadsAgain() async throws {
        let fixture = Fixture()
        fixture.enabled = true
        fixture.helper = .running(42)
        fixture.answer(.answered(.none, helper: nil))
        let distributed = NotificationCenter()
        let setup = Self.make(fixture, distributed: distributed)
        try await Self.waitUntil { setup.phase == .ready }
        fixture.answer(.answered(ComputerUsePermissions(accessibility: true, screenRecording: false), helper: nil))
        distributed.post(name: ComputerUseSetup.accessibilityTrustChanged, object: nil)
        try await Self.waitUntil { setup.permissions.accessibility }
    }

    @Test func aHelperThatIsNotUpYetIsReadAgainAfterABackoff() async throws {
        let fixture = Fixture()
        fixture.enabled = true
        fixture.helper = .running(42)
        fixture.answer(.noAnswer, .answered(ComputerUsePermissions(accessibility: true, screenRecording: true), helper: nil))
        let clock = ManualClock()
        let setup = Self.make(fixture, clock: clock)
        await clock.sleepers(atLeast: 1)
        #expect(setup.phase == .starting)
        #expect(fixture.readCount == 1)
        clock.advance(by: .seconds(5))
        try await Self.waitUntil { setup.phase == .ready }
        #expect(setup.permissions.allGranted)
    }

    @Test func turningComputerUseOnStartsTheReads() async throws {
        let fixture = Fixture()
        fixture.answer(.answered(ComputerUsePermissions(accessibility: false, screenRecording: true), helper: nil))
        let setup = Self.make(fixture)
        try await Self.waitUntil { setup.helperAppURL != nil }
        setup.enable()
        #expect(fixture.enables == 1)
        try await Self.waitUntil { setup.phase == .starting }
        fixture.helper = .running(7)
        try await Self.waitUntil { setup.phase == .ready }
        #expect(setup.permissions.screenRecording)
        setup.enable()
        #expect(fixture.enables == 1, "enable only acts while off")
    }

    @Test func eachGrantOpensItsOwnList() {
        let fixture = Fixture()
        let setup = Self.make(fixture)
        setup.open(.accessibility)
        setup.open(.screenRecording)
        #expect(fixture.opened.map(\.query) == ["Privacy_Accessibility", "Privacy_ScreenCapture"])
    }

    @Test func aHelperOnAnotherProtocolIsReported() async throws {
        let fixture = Fixture()
        fixture.enabled = true
        fixture.helper = .running(42)
        fixture.answer(.versionMismatch)
        let setup = Self.make(fixture)
        try await Self.waitUntil { setup.phase == .versionMismatch }
        #expect(setup.stepPermissions.helperVersionMismatch)
    }

    /// The Settings card's state: grants are null until the helper answered.
    @Test func theSettingsCardStateHidesUnknownGrants() async throws {
        let fixture = Fixture()
        let setup = Self.make(fixture)
        try await Self.waitUntil { setup.helperAppURL != nil }
        let off = setup.pageJSON
        #expect(off.objectValue?["phase"] == .string("off"))
        #expect(off.objectValue?["accessibility"] == .null)
        #expect(off.objectValue?["helper"] == .string("cmux Computer Use"))
    }
}
