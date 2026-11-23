@testable import CmuxNextUpdater
import Foundation
import Testing

/// The rollback's check of the stored schemas has a fixed time (``StoreSchemaProbe``). A check
/// that cannot read each session in that time says so itself, with how many sessions it read
/// (cmux-tui `store_schemas.rs`). The probe asks again while that count grows, and asks one time
/// with no end time when it does not. The last call that a state folder can use is that call with
/// no end time, and one call stays for each state folder after it. Each test runs the probe
/// against a script in the place of the bundle's CLI; the script answers by the count of its
/// calls for a state folder.
struct RollbackCheckInItsTimeTests {
    /// The check's answer when it read each session.
    private static let numbers = #"{"workspace_registry":15}"#
    /// In the place of an answer: the script stops with a failure at that call.
    private static let failure = "exit 1"
    /// The arguments of a call with the end time, and of a call with none.
    private static let inItsTime = "__store-schemas --stored --within-ms 5000"
    private static let plain = "__store-schemas --stored"

    /// A bundle whose CLI is a script that gives `answers` in turn, the last one for each call
    /// after it, and a state folder. The script writes the arguments of each call into the file
    /// `calls` of the state folder. With `refusingAnEndTime` the script is a CLI of a build from
    /// before the check had an end time: it stops with a failure when a call has `--within-ms`.
    /// With `withNoEndTime` the script gives that answer to each call that has no `--within-ms`.
    private static func bundle(
        answering answers: [String], refusingAnEndTime: Bool = false, withNoEndTime: String? = nil
    ) throws -> (bundle: URL, state: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "RollbackCheckInItsTimeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let bundle = root.appending(path: "cmux.app", directoryHint: .isDirectory)
        let bin = bundle.appending(path: "Contents/Resources/bin", directoryHint: .isDirectory)
        let state = root.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        var cases = ""
        for (index, answer) in answers.enumerated() {
            let pattern = index == answers.count - 1 ? "*" : String(index + 1)
            cases += answer == failure ? "\(pattern)) exit 1 ;;\n" : "\(pattern)) echo '\(answer)' ;;\n"
        }
        let refusal = refusingAnEndTime ? "case \"$*\" in *--within-ms*) exit 1 ;; esac\n" : ""
        let noEndTime = withNoEndTime
            .map { "case \"$*\" in *--within-ms*) ;; *) echo '\($0)'; exit 0 ;; esac\n" } ?? ""
        let script = """
            #!/bin/sh
            echo "$*" >> "$CMUX_TUI_STATE_DIR/calls"
            \(refusal)\(noEndTime)case "$(wc -l < "$CMUX_TUI_STATE_DIR/calls" | tr -d ' ')" in
            \(cases)esac
            """
        let cli = bin.appending(path: "cmux").path
        try script.write(toFile: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli)
        return (bundle, state)
    }

    /// The arguments of each call the script got, in order.
    private static func calls(_ state: URL) -> [String] {
        let text = (try? String(contentsOf: state.appending(path: "calls"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    private static func notReady(_ read: Int, of sessions: Int) -> String {
        #"{"not_ready":{"sessions":\#(sessions),"sessions_read":\#(read)}}"#
    }

    @Test func aCheckThatSaysNotReadyWithAGrowingCountIsAskedAgainUntilItGivesTheNumbers() async throws {
        let (bundle, state) = try Self.bundle(answering: [
            Self.notReady(1, of: 3), Self.notReady(2, of: 3), Self.numbers,
        ])
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        let stored = await StoreSchemaProbe(bundle: bundle).stored(stateDirectories: [state])

        #expect(stored == ["workspace_registry": 15])
        #expect(Self.calls(state).count == 3)
    }

    @Test func aCheckWhoseCountDoesNotGrowIsAskedOneTimeWithNoEndTime() async throws {
        let (bundle, state) = try Self.bundle(answering: [
            Self.notReady(1, of: 3), Self.notReady(1, of: 3), Self.numbers,
        ])
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        let stored = await StoreSchemaProbe(bundle: bundle).stored(stateDirectories: [state])

        #expect(stored == ["workspace_registry": 15])
        #expect(Self.calls(state) == [Self.inItsTime, Self.inItsTime, Self.plain])
    }

    @Test func theProbeGivesTheCheckAnEndTimeBelowItsOwn() async throws {
        let (bundle, state) = try Self.bundle(answering: [Self.numbers])
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        let stored = await StoreSchemaProbe(bundle: bundle).stored(stateDirectories: [state])

        #expect(stored == ["workspace_registry": 15])
        #expect(Self.calls(state) == [Self.inItsTime])
    }

    @Test func aCheckInOneStateFolderWhoseCountGrowsEachTimeGetsItsSixthCallWithNoEndTime() async throws {
        let (bundle, state) = try Self.bundle(
            answering: (1...8).map { Self.notReady($0, of: 9) }, withNoEndTime: Self.numbers)
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        let stored = await StoreSchemaProbe(bundle: bundle).stored(stateDirectories: [state])

        #expect(stored == ["workspace_registry": 15])
        #expect(Self.calls(state) == Array(repeating: Self.inItsTime, count: 5) + [Self.plain])
    }

    @Test func aSixthCallWithNoEndTimeThatIsNotReadyIsNoAnswerWithNoCallMore() async throws {
        let (bundle, state) = try Self.bundle(
            answering: (1...8).map { Self.notReady($0, of: 9) } + [Self.numbers])
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        let stored = await StoreSchemaProbe(bundle: bundle).stored(stateDirectories: [state])

        #expect(stored == nil)
        #expect(Self.calls(state) == Array(repeating: Self.inItsTime, count: 5) + [Self.plain])
    }

    @Test func theProbeCallsTheCheckSixTimesAtMostForAllStateFoldersTogether() async throws {
        let (bundle, state) = try Self.bundle(answering: [
            Self.notReady(1, of: 9), Self.notReady(2, of: 9), Self.notReady(3, of: 9), Self.numbers,
        ])
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let second = state.deletingLastPathComponent()
            .appending(path: "sessions-2", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let stored = await StoreSchemaProbe(bundle: bundle).stored(stateDirectories: [state, second])

        #expect(stored == nil)
        #expect(Self.calls(state).count == 4)
        #expect(Self.calls(second).count == 2)
    }

    @Test func aStateFolderWhoseCountGrowsEachTimeLeavesOneCallForTheFolderAfterIt() async throws {
        let (bundle, state) = try Self.bundle(
            answering: (1...8).map { Self.notReady($0, of: 9) }, withNoEndTime: Self.numbers)
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let second = state.deletingLastPathComponent()
            .appending(path: "sessions-2", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let stored = await StoreSchemaProbe(bundle: bundle).stored(stateDirectories: [state, second])

        #expect(stored == ["workspace_registry": 15])
        #expect(Self.calls(state) == Array(repeating: Self.inItsTime, count: 4) + [Self.plain])
        #expect(Self.calls(second) == [Self.plain])
    }

    @Test func moreStateFoldersThanCallsGetOneCallWithNoEndTimeEach() async throws {
        let (bundle, state) = try Self.bundle(answering: [Self.numbers])
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        var folders = [state]
        for index in 2...7 {
            let folder = state.deletingLastPathComponent()
                .appending(path: "sessions-\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            folders.append(folder)
        }

        let stored = await StoreSchemaProbe(bundle: bundle).stored(stateDirectories: folders)

        #expect(stored == ["workspace_registry": 15])
        #expect(folders.map { Self.calls($0) } == Array(repeating: [Self.plain], count: 7))
    }

    @Test func aCheckOfABuildWithNoEndTimeIsAskedOneTimeMoreWithoutIt() async throws {
        let (bundle, state) = try Self.bundle(answering: [Self.numbers], refusingAnEndTime: true)
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        let stored = await StoreSchemaProbe(bundle: bundle).stored(stateDirectories: [state])

        #expect(stored == ["workspace_registry": 15])
        #expect(Self.calls(state) == [Self.inItsTime, Self.plain])
    }

    @Test func aNotReadyAnswerWithNoCountIsAskedOneTimeWithNoEndTime() async throws {
        let (bundle, state) = try Self.bundle(answering: [#"{"not_ready":{}}"#, Self.numbers])
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        let stored = await StoreSchemaProbe(bundle: bundle).stored(stateDirectories: [state])

        #expect(stored == ["workspace_registry": 15])
        #expect(Self.calls(state) == [Self.inItsTime, Self.plain])
    }

    @Test func aCountThatIsNotANumberIsNoCount() async throws {
        let (bundle, state) = try Self.bundle(answering: [
            #"{"not_ready":{"sessions":3,"sessions_read":true}}"#, Self.numbers,
        ])
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        let stored = await StoreSchemaProbe(bundle: bundle).stored(stateDirectories: [state])

        #expect(stored == ["workspace_registry": 15])
        #expect(Self.calls(state) == [Self.inItsTime, Self.plain])
    }

    @Test func aCheckWhoseCountIsSmallerIsAskedOneTimeWithNoEndTime() async throws {
        let (bundle, state) = try Self.bundle(answering: [
            Self.notReady(2, of: 3), Self.notReady(1, of: 3), Self.numbers,
        ])
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        let stored = await StoreSchemaProbe(bundle: bundle).stored(stateDirectories: [state])

        #expect(stored == ["workspace_registry": 15])
        #expect(Self.calls(state) == [Self.inItsTime, Self.inItsTime, Self.plain])
    }

    @Test func aCallWithNoEndTimeThatFailsIsNoAnswer() async throws {
        let (bundle, state) = try Self.bundle(answering: [Self.failure])
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        let stored = await StoreSchemaProbe(bundle: bundle).stored(stateDirectories: [state])

        #expect(stored == nil)
        #expect(Self.calls(state) == [Self.inItsTime, Self.plain])
    }

    @Test func aFailureAtALaterAskIsAskedOneTimeWithNoEndTime() async throws {
        let (bundle, state) = try Self.bundle(answering: [
            Self.notReady(1, of: 3), Self.failure, Self.numbers,
        ])
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        let stored = await StoreSchemaProbe(bundle: bundle).stored(stateDirectories: [state])

        #expect(stored == ["workspace_registry": 15])
        #expect(Self.calls(state) == [Self.inItsTime, Self.inItsTime, Self.plain])
    }

    @Test func aCLIThatIsNotThereIsNoAnswer() async throws {
        let (bundle, state) = try Self.bundle(answering: [Self.numbers])
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: bundle.appending(path: "Contents/Resources/bin/cmux"))

        let stored = await StoreSchemaProbe(bundle: bundle).stored(stateDirectories: [state])

        #expect(stored == nil)
        #expect(Self.calls(state).isEmpty)
    }

    @Test func aFirstStateFolderWithNoAnswerIsNoAnswerForAllWithNoCallForTheSecond() async throws {
        let (bundle, state) = try Self.bundle(answering: [Self.failure])
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let second = state.deletingLastPathComponent()
            .appending(path: "sessions-2", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let stored = await StoreSchemaProbe(bundle: bundle).stored(stateDirectories: [state, second])

        #expect(stored == nil)
        #expect(Self.calls(state) == [Self.inItsTime, Self.plain])
        #expect(Self.calls(second).isEmpty)
    }

    @Test func aCallWithNoEndTimeIsNotMadeASecondTimeForAStateFolder() async throws {
        let (bundle, state) = try Self.bundle(answering: [Self.notReady(1, of: 3)])
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        let stored = await StoreSchemaProbe(bundle: bundle).stored(stateDirectories: [state])

        #expect(stored == nil)
        #expect(Self.calls(state) == [Self.inItsTime, Self.inItsTime, Self.plain])
    }

    /// An ask that ends with exit 0 and an output that is not the numbers and not a `not_ready`
    /// answer is no answer, and the probe makes no call more for that state folder. The script
    /// has the numbers for each call after the first: a probe that calls again gets them.
    @Test func anOutputOfNeitherFormIsNoAnswerWithNoCallMore() async throws {
        let (bundle, state) = try Self.bundle(answering: ["[]", Self.numbers])
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        let stored = await StoreSchemaProbe(bundle: bundle).stored(stateDirectories: [state])

        #expect(stored == nil)
        #expect(Self.calls(state) == [Self.inItsTime])
    }
}
