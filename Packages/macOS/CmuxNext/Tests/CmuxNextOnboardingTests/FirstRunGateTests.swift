import Foundation
import Testing
@testable import CmuxNextOnboarding

/// The has-data rule (plans/cmux-next/onboarding.md 4, S1): the first run
/// shows only when all five checks pass; any data of the user's own ends it
/// silently with `reason: existing-data`, and a finished record stays finished.
@Suite struct FirstRunGateTests {
    static func stateFile() -> OnboardingStateFile {
        OnboardingStateFile(url: FileManager.default.temporaryDirectory
            .appending(path: "first-run-gate-\(UUID().uuidString)/onboarding.json"))
    }

    /// A fresh profile: no workspace, no acpmux session, no cmux-next config,
    /// no classic snapshot.
    static let fresh = FirstRunGate(firstWorkspaceNeeded: true, agentSessions: 0, config: .absent, classicSnapshot: false)

    @Test func aFreshProfileShowsTheFirstRun() {
        #expect(Self.fresh.decide(launch: .start) == .firstRun)
        #expect(Self.fresh.decide(launch: .resume(.accounts)) == .firstRun)
        var empty = Self.fresh
        empty.config = .empty
        #expect(empty.decide(launch: .start) == .firstRun, "a {} config written before is not data")
    }

    /// Each check alone flips the result.
    @Test(arguments: [
        (FirstRunGate(firstWorkspaceNeeded: false, agentSessions: 0, config: .absent, classicSnapshot: false), FirstRunGate.Check.workspaces),
        (FirstRunGate(firstWorkspaceNeeded: true, agentSessions: 1, config: .absent, classicSnapshot: false), .agentSessions),
        (FirstRunGate(firstWorkspaceNeeded: true, agentSessions: 0, config: .settings, classicSnapshot: false), .config),
        (FirstRunGate(firstWorkspaceNeeded: true, agentSessions: 0, config: .seededFromClassic, classicSnapshot: false), .config),
        (FirstRunGate(firstWorkspaceNeeded: true, agentSessions: 0, config: .absent, classicSnapshot: true), .classicSnapshot),
    ])
    func eachCheckAloneEndsTheFirstRun(gate: FirstRunGate, check: FirstRunGate.Check) {
        #expect(gate.decide(launch: .start) == .existingData(check))
    }

    @Test func aFinishedStateFileShowsNothingAndRecordsNothing() {
        #expect(Self.fresh.decide(launch: .none) == .decided)
        let withData = FirstRunGate(firstWorkspaceNeeded: false, agentSessions: 3, config: .settings, classicSnapshot: true)
        #expect(withData.decide(launch: .none) == .decided)
    }

    /// Existing data: one queued call ends the first run with the reason, and
    /// later launches stay decided.
    @Test func existingDataFinishesTheRecordWithItsReason() throws {
        let file = Self.stateFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let withWorkspaces = FirstRunGate(firstWorkspaceNeeded: false, agentSessions: 0, config: .absent, classicSnapshot: false)
        #expect(file.decideFirstRun(withWorkspaces) == .existingData(.workspaces))
        let record = try #require(file.record())
        #expect(record.isFinished)
        #expect(!record.completed)
        #expect(record.reason == OnboardingStateFile.EndReason.existingData.rawValue)
        #expect(record.reason == "existing-data")
        #expect(OnboardingStateFile(url: file.url).decideFirstRun(Self.fresh) == .decided, "never shown later")
    }

    /// A fresh profile leaves the record unfinished (S2 shows the page).
    @Test func aFreshProfileLeavesTheRecordUnfinished() throws {
        let file = Self.stateFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        #expect(file.decideFirstRun(Self.fresh) == .firstRun)
        let record = try #require(file.record())
        #expect(!record.isFinished)
        #expect(record.reason == nil)
    }

    /// A user who finished onboarding before (version 1, no reason, no
    /// firstRun) stays finished and the record is not rewritten.
    @Test func anExistingFinishedRecordStaysFinished() throws {
        let file = Self.stateFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = #"{"version":1,"completed":true,"date":700000000,"finished":true,"step":"importData"}"#
        try Data(old.utf8).write(to: file.url)
        #expect(file.decideFirstRun(Self.fresh) == .decided)
        let record = try #require(file.record())
        #expect(record.isFinished)
        #expect(record.completed)
        #expect(record.reason == nil)
        #expect(record.step == "importData")
        #expect(try String(contentsOf: file.url, encoding: .utf8) == old, "the file is not rewritten")
    }

    @Test func theRecordRoundTripsReasonAndFirstRun() throws {
        var firstRun = OnboardingStateFile.FirstRun()
        firstRun.stage = .promptSent
        firstRun.action = .prompt
        firstRun.firstPromptMilliseconds = 12_345
        firstRun.openedMakeItYours = true
        let record = OnboardingStateFile.Record(version: 1, completed: false, date: Date(timeIntervalSinceReferenceDate: 1),
                                                finished: true, reason: "existing-data", firstRun: firstRun)
        let decoded = try JSONDecoder().decode(OnboardingStateFile.Record.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
        #expect(decoded.version == OnboardingStateFile.currentVersion, "still version 1")
    }

    /// A later build's stage or action does not reset the record.
    @Test func anUnknownStageOrActionKeepsTheRecord() throws {
        let json = #"{"version":1,"completed":true,"date":1,"finished":true,"reason":"existing-data","firstRun":{"stage":"futureStage","action":"futureAction","firstPromptMilliseconds":9}}"#
        let record = try JSONDecoder().decode(OnboardingStateFile.Record.self, from: Data(json.utf8))
        #expect(record.isFinished)
        #expect(record.firstRun?.stage == nil)
        #expect(record.firstRun?.action == nil)
        #expect(record.firstRun?.firstPromptMilliseconds == 9)
    }

    /// Skip or Done after an existing-data end keeps it finished, completed
    /// only when the user completed it.
    @Test func markDoneWithoutReasonClearsNoFinishedState() throws {
        let file = Self.stateFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        try file.markDone(completed: false, reason: .existingData)
        #expect(file.record()?.reason == "existing-data")
        try file.markDone(completed: true)
        let record = try #require(file.record())
        #expect(record.isFinished)
        #expect(record.completed)
        #expect(record.reason == nil)
    }
}
