import AppKit
import CmuxNextActions
import CmuxNextDaemon
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// Quit and the local terminals (user decision 2026-09-30): the terminals
/// run in cmux-tui and outlive the app, so an interactive quit asks whether
/// to keep them only while one runs a program (#17501); scripted quits,
/// power off and a remembered choice never wait on the sheet; incognito
/// windows fold their close confirmation in; a quit asks at most once.
@MainActor
struct QuitPolicyTests {
    static let busy = QuitFacts(
        terminals: 4,
        programs: [QuitProgram(name: "vim", cpuNanos: 5), QuitProgram(name: "claude", cpuNanos: 900),
                   QuitProgram(name: "npm", cpuNanos: 300), QuitProgram(name: "claude", cpuNanos: 10),
                   QuitProgram(name: "htop", cpuNanos: 1)],
        incognitoPrograms: [], remoteSessions: false)
    static let idle = QuitFacts(terminals: 2, programs: [], incognitoPrograms: [], remoteSessions: false)

    @Test func interactiveQuitWithTerminalsAsksWithCountsAndTheBusiestPrograms() throws {
        guard case .ask(let prompt) = QuitPolicy.decide(.interactive, behavior: .ask, facts: Self.busy) else {
            Issue.record("expected the sheet"); return
        }
        #expect(prompt.terminals == 4)
        #expect(prompt.runningPrograms == 5)
        #expect(prompt.busiest == ["claude", "npm", "vim"])
        #expect(prompt.offersSessionChoice)
        #expect(prompt.defaultChoice == .keep)
        #expect(!prompt.remoteSessions)
    }

    /// Idle shells keep running and reattach: nothing to ask (#17501).
    @Test func idleShellsQuitWithoutAsking() {
        #expect(QuitPolicy.decide(.interactive, behavior: .ask, facts: Self.idle) == .quit(.keep))
    }

    /// After "Save changes before quitting?" the quit asks nothing more.
    @Test func theUnsavedQuestionIsTheOnlyQuestion() {
        var facts = Self.busy
        facts.incognitoPrograms = ["npm"]
        #expect(QuitPolicy.decide(.interactive, behavior: .ask, facts: facts, alreadyAsked: true) == .quit(.keep))
        #expect(QuitPolicy.decide(.interactive, behavior: .endKeepLayout, facts: facts, alreadyAsked: true) == .quit(.endKeepLayout))
    }

    @Test func noLocalTerminalsQuitsWithoutAsking() {
        var facts = QuitFacts.none
        facts.remoteSessions = true
        #expect(QuitPolicy.decide(.interactive, behavior: .ask, facts: facts) == .quit(.keep))
    }

    @Test func aRememberedChoiceQuitsWithoutAsking() {
        #expect(QuitPolicy.decide(.interactive, behavior: .keep, facts: Self.busy) == .quit(.keep))
        #expect(QuitPolicy.decide(.interactive, behavior: .endKeepLayout, facts: Self.busy) == .quit(.endKeepLayout))
        #expect(QuitPolicy.decide(.interactive, behavior: .endEverything, facts: Self.busy) == .quit(.endEverything))
    }

    @Test func scriptedQuitFollowsTheSettingAndNeverAsks() {
        #expect(QuitPolicy.decide(.scripted, behavior: .ask, facts: Self.busy) == .quit(.keep))
        #expect(QuitPolicy.decide(.scripted, behavior: .keep, facts: Self.busy) == .quit(.keep))
        #expect(QuitPolicy.decide(.scripted, behavior: .endKeepLayout, facts: Self.busy) == .quit(.endKeepLayout))
        #expect(QuitPolicy.decide(.scripted, behavior: .endEverything, facts: Self.busy) == .quit(.endEverything))
        #expect(!QuitPolicy.needsFacts(.scripted))
    }

    @Test func explicitChoicesRunAsAsked() {
        for behavior in QuitBehavior.allCases {
            #expect(QuitPolicy.decide(.explicit(.keep), behavior: behavior, facts: Self.busy) == .quit(.keep))
            #expect(QuitPolicy.decide(.explicit(.endKeepLayout), behavior: behavior, facts: Self.busy) == .quit(.endKeepLayout))
            #expect(QuitPolicy.decide(.explicit(.endEverything), behavior: behavior, facts: Self.busy) == .quit(.endEverything))
        }
    }

    @Test func powerOffNeverAsksAndNeverEnds() {
        var facts = Self.busy
        facts.incognitoPrograms = ["vim"]
        for behavior in QuitBehavior.allCases {
            #expect(QuitPolicy.decide(.powerOff, behavior: behavior, facts: facts) == .quit(.keep))
        }
        #expect(!QuitPolicy.needsFacts(.powerOff))
        #expect(QuitPolicy.needsFacts(.interactive))
    }

    @Test func remoteSessionsAreMentioned() {
        var facts = Self.busy
        facts.remoteSessions = true
        guard case .ask(let prompt) = QuitPolicy.decide(.interactive, behavior: .ask, facts: facts) else {
            Issue.record("expected the sheet"); return
        }
        #expect(prompt.remoteSessions)
    }

    /// One sheet, not two: incognito programs join the quit sheet, even
    /// with a remembered choice (that choice becomes the default button).
    @Test func incognitoProgramsFoldIntoTheSameSheet() {
        var facts = Self.busy
        facts.incognitoPrograms = ["npm"]
        guard case .ask(let prompt) = QuitPolicy.decide(.interactive, behavior: .endEverything, facts: facts) else {
            Issue.record("expected the sheet"); return
        }
        #expect(prompt.incognitoPrograms == ["npm"])
        #expect(!prompt.offersSessionChoice, "a remembered end is not asked again")
        #expect(prompt.defaultChoice == .endEverything)
    }

    @Test func onlyIncognitoProgramsAskQuitOrCancel() {
        let facts = QuitFacts(terminals: 0, programs: [], incognitoPrograms: ["vim"], remoteSessions: false)
        guard case .ask(let prompt) = QuitPolicy.decide(.interactive, behavior: .ask, facts: facts) else {
            Issue.record("expected the sheet"); return
        }
        #expect(!prompt.offersSessionChoice)
        #expect(prompt.incognitoPrograms == ["vim"])
    }

    // MARK: Origin

    @Test func quitFlagsPickTheOrigin() throws {
        let keep = ActionInvocation(arguments: ["keepSessions": .bool(true)])
        let end = ActionInvocation(arguments: ["endSessions": .bool(true)])
        #expect(try QuitPolicy.origin(for: keep, scripted: true) == .explicit(.keep))
        let everything = ActionInvocation(arguments: ["endEverything": .bool(true)])
        #expect(try QuitPolicy.origin(for: end, scripted: true) == .explicit(.endKeepLayout), "--end-sessions keeps the layout")
        #expect(try QuitPolicy.origin(for: end, scripted: false) == .explicit(.endKeepLayout))
        #expect(try QuitPolicy.origin(for: everything, scripted: true) == .explicit(.endEverything))
        #expect(try QuitPolicy.origin(for: ActionInvocation(), scripted: true) == .scripted)
        #expect(try QuitPolicy.origin(for: ActionInvocation(), scripted: false) == .interactive)
        let both = ActionInvocation(arguments: ["keepSessions": .bool(true), "endSessions": .bool(true)])
        #expect(throws: QuitArgumentConflict.self) { try QuitPolicy.origin(for: both, scripted: true) }
        let endBoth = ActionInvocation(arguments: ["endSessions": .bool(true), "endEverything": .bool(true)])
        #expect(throws: QuitArgumentConflict.self) { try QuitPolicy.origin(for: endBoth, scripted: true) }
    }

    @Test func anUnrecordedQuitIsInteractiveAndARecordedOneIsUsedOnce() {
        let tracker = QuitOriginTracker(center: NotificationCenter())
        #expect(tracker.consume() == .interactive)
        tracker.record(.scripted)
        #expect(tracker.consume() == .scripted)
        #expect(tracker.consume() == .interactive)
    }

    @Test func powerOffWinsOverEveryOrigin() {
        let center = NotificationCenter()
        let tracker = QuitOriginTracker(center: center)
        center.post(name: NSWorkspace.willPowerOffNotification, object: nil)
        tracker.record(.explicit(.endEverything))
        #expect(tracker.consume() == .powerOff)
        let other = QuitOriginTracker(center: NotificationCenter())
        #expect(other.consume(appleEventReason: OSType(kAEShutDown)) == .powerOff)
        #expect(other.consume(appleEventReason: OSType(kAEReallyLogOut)) == .powerOff)
    }

    // MARK: Completion

    @Test func keepLeavesTheSessionsAndEndEndsThemAfterTheWindowsSave() async {
        let choices: [QuitSessionsChoice] = [.keep, .endKeepLayout, .endEverything]
        for choice in choices {
            for remember in [false, true] {
                let log = StepLog()
                await QuitCompletion.run(choice, remember: remember, QuitSteps(
                    remember: { log.steps.append("remember:\($0.rawValue)") },
                    prepareWindows: { log.steps.append("windows") },
                    endLocalSessions: { log.steps.append($0 == .endEverything ? "end+delete-workspaces" : "end"); return [] },
                    confirmFailures: { _ in log.steps.append("confirm"); return .quitAnyway },
                    stopBrowserEngines: { log.steps.append("engines") }
                ))
                var expected = remember ? ["remember:\(choice.rawValue)"] : []
                expected.append("windows")
                switch choice {
                case .keep: break
                case .endKeepLayout: expected.append("end")
                case .endEverything: expected.append("end+delete-workspaces")
                }
                // Chromium's teardown is last: its own 10 s watchdog can end the
                // process with code 2 mid-CefShutdown, which must not skip
                // ending the local sessions.
                expected.append("engines")
                #expect(log.steps == expected, "\(choice) remember=\(remember)")
            }
        }
    }
}

extension QuitPolicyTests {
    /// A failed end step is never passed silently: the failures are shown,
    /// Retry runs the end again until it succeeds, and Chromium still stops
    /// last.
    @Test func aFailedEndAsksAndRetryRunsTheEndAgain() async {
        let log = StepLog()
        log.results = [
            [EndSessionsFailure(step: .shutdownDaemon, message: "timeout")],
            [EndSessionsFailure(step: .closeWorkspace(name: "a"), message: "busy")],
            [],
        ]
        await QuitCompletion.run(.endEverything, remember: false, QuitSteps(
            remember: { _ in },
            prepareWindows: { log.steps.append("windows") },
            endLocalSessions: { _ in log.steps.append("end"); return log.results.removeFirst() },
            confirmFailures: { failures in log.steps.append("confirm:\(failures.count)"); return .retry },
            stopBrowserEngines: { log.steps.append("engines") }
        ))
        #expect(log.steps == ["windows", "end", "confirm:1", "end", "confirm:1", "end", "engines"])
    }

    /// Quit Anyway quits with what did not end, after one question.
    @Test func quitAnywayStopsAfterOneQuestion() async {
        let log = StepLog()
        await QuitCompletion.run(.endKeepLayout, remember: false, QuitSteps(
            remember: { _ in },
            prepareWindows: {},
            endLocalSessions: { _ in log.steps.append("end"); return [EndSessionsFailure(step: .shutdownDaemon, message: "x")] },
            confirmFailures: { _ in log.steps.append("confirm"); return .quitAnyway },
            stopBrowserEngines: { log.steps.append("engines") }
        ))
        #expect(log.steps == ["end", "confirm", "engines"])
    }

    /// One line per failed step, then what Quit Anyway leaves running.
    @Test func failureLinesNameEachStep() {
        let lines = QuitFailureContent.lines([
            EndSessionsFailure(step: .listWorkspaces, message: "m1"),
            EndSessionsFailure(step: .closeWorkspace(name: "build"), message: "m2"),
            EndSessionsFailure(step: .shutdownDaemon, message: "m3"),
            EndSessionsFailure(step: .unsupported, message: "terminal-reap-v1"),
        ])
        #expect(lines.count == 5)
        #expect(lines[0].contains("m1"))
        #expect(lines[1].contains("build") && lines[1].contains("m2"))
        #expect(lines[2].contains("m3"))
        #expect(lines[3].contains("terminal-reap-v1"))
        #expect(lines[4] == QuitStrings.failedKeepRunning)
    }
}

@MainActor
private final class StepLog {
    var steps: [String] = []
    var results: [[EndSessionsFailure]] = []
}
