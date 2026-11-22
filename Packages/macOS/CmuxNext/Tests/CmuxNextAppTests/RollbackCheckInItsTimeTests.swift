@testable import CmuxNextUpdater
import Foundation
import Testing

/// The rollback's check of the stored schemas has a fixed time (``StoreSchemaProbe``). A check
/// that cannot read each session in that time says so itself, with how many sessions it read
/// (cmux-tui `store_schemas.rs`), and the probe asks again while that count grows. Each test runs
/// the probe against a script in the place of the bundle's CLI; the script answers by the count
/// of its calls for a state folder.
struct RollbackCheckInItsTimeTests {
    /// A bundle whose CLI is a script that gives `answers` in turn, the last one for each call
    /// after it, and a state folder. The script writes the arguments of each call into the file
    /// `calls` of the state folder. With `refusingAnEndTime` the script is a CLI of a build from
    /// before the check had an end time: it stops with a failure when a call has `--within-ms`.
    private static func bundle(
        answering answers: [String], refusingAnEndTime: Bool = false
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
            cases += "\(pattern)) echo '\(answer)' ;;\n"
        }
        let refusal = refusingAnEndTime ? "case \"$*\" in *--within-ms*) exit 1 ;; esac\n" : ""
        let script = """
            #!/bin/sh
            echo "$*" >> "$CMUX_TUI_STATE_DIR/calls"
            \(refusal)case "$(wc -l < "$CMUX_TUI_STATE_DIR/calls" | tr -d ' ')" in
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
            Self.notReady(1, of: 3), Self.notReady(2, of: 3), #"{"workspace_registry":15}"#,
        ])
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        let stored = await StoreSchemaProbe(bundle: bundle).stored(stateDirectories: [state])

        #expect(stored == ["workspace_registry": 15])
        #expect(Self.calls(state).count == 3)
    }

    @Test func aCheckWhoseCountDoesNotGrowIsNoAnswerAfterTheSecondCall() async throws {
        let (bundle, state) = try Self.bundle(answering: [Self.notReady(1, of: 3)])
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        let stored = await StoreSchemaProbe(bundle: bundle).stored(stateDirectories: [state])

        #expect(stored == nil)
        #expect(Self.calls(state).count == 2)
    }

    @Test func theProbeGivesTheCheckAnEndTimeBelowItsOwn() async throws {
        let (bundle, state) = try Self.bundle(answering: [#"{"workspace_registry":15}"#])
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        let stored = await StoreSchemaProbe(bundle: bundle).stored(stateDirectories: [state])

        #expect(stored == ["workspace_registry": 15])
        #expect(Self.calls(state) == ["__store-schemas --stored --within-ms 5000"])
    }

    @Test func theProbeCallsTheCheckSixTimesAtMostForAllStateFoldersTogether() async throws {
        let (bundle, state) = try Self.bundle(answering: [
            Self.notReady(1, of: 9), Self.notReady(2, of: 9), Self.notReady(3, of: 9),
            #"{"workspace_registry":15}"#,
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

    @Test func aCheckOfABuildWithNoEndTimeIsAskedOneTimeMoreWithoutIt() async throws {
        let (bundle, state) = try Self.bundle(
            answering: [#"{"workspace_registry":15}"#], refusingAnEndTime: true)
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        let stored = await StoreSchemaProbe(bundle: bundle).stored(stateDirectories: [state])

        #expect(stored == ["workspace_registry": 15])
        #expect(Self.calls(state) == [
            "__store-schemas --stored --within-ms 5000", "__store-schemas --stored",
        ])
    }
}
