@testable import CmuxNextUpdater
import Foundation
import Testing

/// Update Status (`updates.status`, `cmux settings update-status`): the running build, the staged
/// update and whether a relaunch installs it now, for each state the updater can be in.
@MainActor @Suite struct UpdateStatusAnswerTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func fields(_ phase: UpdateIndicatorPhase, staged: String? = nil, hold: UpdateRelaunchHoldState? = nil,
                       unavailable: String? = nil) -> [String: UpdateAnswerField] {
        UpdaterService.statusFields(version: "1.0.0", build: "100", track: "nightly-next", phase: phase,
                                    stagedVersion: staged, hold: hold, unavailable: unavailable, now: now)
    }

    @Test func idleReportsTheRunningBuildAndNothingStaged() {
        let fields = Self.fields(.hidden)
        #expect(fields["current_version"] == .string("1.0.0"))
        #expect(fields["current_build"] == .string("100"))
        #expect(fields["track"] == .string("nightly-next"))
        #expect(fields["state"] == .string("idle"))
        #expect(fields["staged"] == .bool(false))
        #expect(fields["staged_version"] == nil)
        #expect(fields["relaunch"] == .string("nothing_staged"))
        #expect(fields["pending"] == nil)
        guard case .string(let line)? = fields["line"] else { Issue.record("no line"); return }
        #expect(line.contains("1.0.0 (100)"))
    }

    @Test func aStagedUpdateIsReadyToRelaunch() {
        let fields = Self.fields(.ready(version: "1.1.0"))
        #expect(fields["state"] == .string("ready"))
        #expect(fields["staged"] == .bool(true))
        #expect(fields["staged_version"] == .string("1.1.0"))
        #expect(fields["relaunch"] == .string("ready"))
        #expect(fields["relaunch_hold"] == nil)
    }

    @Test func aStagedUpdateWithNoShownVersionNamesTheStagedOne() {
        let fields = Self.fields(.ready(version: nil), staged: "1.1.0")
        #expect(fields["staged_version"] == .string("1.1.0"))
    }

    @Test func aHeldRelaunchSaysWhyAndHowLong() {
        let hold = UpdateRelaunchHoldState(reason: .notIdle, since: Self.now.addingTimeInterval(-90))
        let fields = Self.fields(.ready(version: "1.1.0"), hold: hold)
        #expect(fields["staged"] == .bool(true))
        #expect(fields["relaunch"] == .string("held"))
        #expect(fields["relaunch_hold"] == .string(UpdateRelaunchMoment.Interruption.notIdle.rawValue))
        #expect(fields["relaunch_hold_seconds"] == .double(90))
        guard case .string(let line)? = fields["line"] else { Issue.record("no line"); return }
        #expect(line.contains(UpdateRelaunchMoment.Interruption.notIdle.description))
    }

    @Test func aHoldWithNothingStagedIsNotReported() {
        let hold = UpdateRelaunchHoldState(reason: .modal, since: Self.now)
        let fields = Self.fields(.downloading(UpdateTransfer(stage: .downloading)), hold: hold)
        #expect(fields["state"] == .string("downloading"))
        #expect(fields["staged"] == .bool(false))
        #expect(fields["relaunch"] == .string("nothing_staged"))
        #expect(fields["relaunch_hold"] == nil)
    }

    @Test func installingIsItsOwnReadiness() {
        let fields = Self.fields(.installing, staged: "1.1.0")
        #expect(fields["relaunch"] == .string("installing"))
        #expect(fields["staged_version"] == .string("1.1.0"))
    }

    @Test func aBuildThatCannotInstallSaysWhy() {
        let fields = Self.fields(.hidden, unavailable: "The updater is not available in this build.")
        #expect(fields["updates_unavailable"] == .string("The updater is not available in this build."))
    }

    /// The live updater's answer: a DEV build with nothing staged.
    @Test func theRunningUpdaterAnswers() {
        let fields = UpdateActionResultTests.updater(nil).statusAnswer(now: Self.now)
        #expect(fields["current_build"] == .string("100"))
        #expect(fields["relaunch"] == .string("nothing_staged"))
    }
}
