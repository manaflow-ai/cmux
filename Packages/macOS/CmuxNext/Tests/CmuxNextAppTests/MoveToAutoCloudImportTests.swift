import AppKit
@testable import CmuxNextImportCards
import CmuxNextImportSuggestions
import Foundation
import Testing

/// Move this Mac to AutoCloud's run (``MoveToAutoCloudImport``) against a fake `cmux`: the dry run
/// writes the plan, the preview decides, and apply runs that same plan file.
@MainActor @Suite(.serialized)
struct MoveToAutoCloudImportTests {
    /// The run's toasts read `NSApp`'s windows (none here, so none shows).
    init() { _ = NSApplication.shared }

    /// What `cmux migrate plan laptop --preview --json` prints (cmux-migrate `preview.rs`).
    static let preview = """
    {"moving":2,"names":["app","web"],"more":false,"already":1,"carry":1,
     "warnings":["web has uncommitted changes: they come along as a patch"],
     "left":1,"left_rows":["Docker volumes: not copied"]}
    """

    /// A fake `cmux`: `migrate plan … --out FILE --preview` writes a plan there and prints
    /// `preview`; every call is recorded.
    final class CLI {
        var preview = MoveToAutoCloudImportTests.preview
        var applyStatus: Int32 = 0
        /// What `migrate apply PLAN --json` prints on stdout (cli `finish_answer`).
        var applied = #"{"events":[],"failed":0,"median_first_chat_ms":null,"moved":2,"left":0}"#
        /// Its stderr event lines, each handed to the line callback.
        var stepLines: [String] = []
        private(set) var calls: [[String]] = []

        func run(_ arguments: [String], _ timeout: Duration, _ line: (@Sendable (String) -> Void)? = nil) throws -> MoveToAutoCloudImport.Ran {
            calls.append(arguments)
            if arguments.prefix(2) == ["migrate", "plan"], let out = arguments.firstIndex(of: "--out") {
                try Data("{}".utf8).write(to: URL(fileURLWithPath: arguments[out + 1]))
                return .init(status: 0, output: Data(preview.utf8), reason: "")
            }
            stepLines.forEach { line?($0) }
            return .init(status: applyStatus, output: Data(applied.utf8), reason: stepLines.last ?? "exit \(applyStatus)")
        }
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "move-to-autocloud-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func confirmedPlanIsAppliedFromTheSameFile() async throws {
        let cli = CLI()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var shown: MoveToAutoCloudImport.Preview?
        var progress: [Double] = []
        let move = MoveToAutoCloudImport(cli: { try cli.run($0, $1, $2) }, confirm: { shown = $0; return true }, folder: folder)
        let moved = try await move.run { progress.append($0) }
        #expect(moved == 2)
        #expect(shown?.names == ["app", "web"])
        #expect(cli.calls.count == 2)
        let file = try #require(cli.calls.first?[4])
        #expect(cli.calls[0] == ["migrate", "plan", "laptop", "--out", file, "--preview", "--json"])
        #expect(cli.calls[1] == ["migrate", "apply", file, "--json"])
        #expect(progress == [1])
        // The plan file is the run's own and goes with it.
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @Test func declinedPreviewAppliesNothing() async throws {
        let cli = CLI()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let move = MoveToAutoCloudImport(cli: { try cli.run($0, $1, $2) }, confirm: { _ in false }, folder: folder)
        #expect(try await move.run() == nil)
        #expect(cli.calls.map { $0.prefix(2) } == [["migrate", "plan"]])
    }

    /// Nothing left to move (an empty Mac, or a rerun after everything moved) is not a move:
    /// the run returns nil, so the card is not shown as done.
    @Test func aPlanWithNothingToMoveAsksNothing() async throws {
        let cli = CLI()
        cli.preview = #"{"moving":0,"already":3}"#
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var asked = false
        let move = MoveToAutoCloudImport(cli: { try cli.run($0, $1, $2) }, confirm: { _ in asked = true; return true }, folder: folder)
        #expect(try await move.run() == nil)
        #expect(!asked && cli.calls.count == 1)
    }

    @Test func aFailedApplyThrowsItsReason() async throws {
        let cli = CLI()
        cli.applyStatus = 1
        cli.applied = #"{"events":[],"failed":1,"median_first_chat_ms":null,"moved":0,"left":2,"reason":"create-machine ~/code/app: not signed in"}"#
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let move = MoveToAutoCloudImport(cli: { try cli.run($0, $1, $2) }, confirm: { _ in true }, folder: folder)
        await #expect(throws: MoveToAutoCloudFailure.apply("create-machine ~/code/app: not signed in")) { try await move.run() }
    }

    /// The preview lists the projects that move, what comes along, the CLI's warnings and what stays.
    @Test func previewListsProjectsWarningsAndWhatStays() throws {
        let preview = try JSONDecoder().decode(MoveToAutoCloudImport.Preview.self, from: Data(Self.preview.utf8))
        let lines = MoveToAutoCloudImport.previewLines(preview)
        #expect(lines.first == MoveToAutoCloudStrings.projects(2))
        #expect(lines.contains("• app") && lines.contains("• web") && !lines.contains("• old"))
        #expect(lines.contains(MoveToAutoCloudStrings.carry(1)))
        #expect(lines.contains("web has uncommitted changes: they come along as a patch"))
        #expect(lines.contains(MoveToAutoCloudStrings.unsupported(1)) && lines.contains("• Docker volumes: not copied"))
        #expect(lines.last == MoveToAutoCloudStrings.unchanged)
    }

    /// Apply ended without a failed step yet left projects (#59280 F2): the card is not "moved",
    /// it fails with Try Again.
    @Test func anUnfinishedApplyThrowsWhatIsLeft() async throws {
        let cli = CLI()
        cli.applied = #"{"events":[],"failed":0,"median_first_chat_ms":null,"moved":1,"left":1}"#
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let move = MoveToAutoCloudImport(cli: { try cli.run($0, $1, $2) }, confirm: { _ in true }, folder: folder)
        await #expect(throws: MoveToAutoCloudFailure.unfinished(moved: 1, left: 1)) { try await move.run() }
    }

    /// The card counts what this run moved, not what the preview promised.
    @Test func theCardCountsWhatApplyMoved() async throws {
        let cli = CLI()
        cli.applied = #"{"events":[],"failed":0,"median_first_chat_ms":null,"moved":1,"left":0}"#
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let move = MoveToAutoCloudImport(cli: { try cli.run($0, $1, $2) }, confirm: { _ in true }, folder: folder)
        #expect(try await move.run() == 1)
    }

    /// Exit 0 with no answer on stdout is not a move.
    @Test func anApplyWithoutItsAnswerFails() async throws {
        let cli = CLI()
        cli.applied = ""
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let move = MoveToAutoCloudImport(cli: { try cli.run($0, $1, $2) }, confirm: { _ in true }, folder: folder)
        await #expect(throws: MoveToAutoCloudFailure.self) { try await move.run() }
    }

    /// Apply's step lines move the card's progress forward as they come (#59280 F2); a line that
    /// lands after the run's end is dropped.
    @Test func stepLinesMoveProgressForward() async throws {
        var seen: [Double] = []
        let gate = MoveToAutoCloudImport.ProgressGate { seen.append($0) }
        let line = MoveToAutoCloudImport.stepLines(gate)
        line(#"{"step":"create-machine","progress":0.25}"#)
        line(#"{"step":"create-machine","progress":0.5}"#)
        line("not json")
        for _ in 0..<1000 where seen.count < 2 { await Task.yield() }
        #expect(seen == [0.25, 0.5])
        gate.report(1)
        gate.report(0.75)
        #expect(seen == [0.25, 0.5, 1])
    }

    @Test func previewSaysWhatAnEarlierMoveAlreadyMoved() throws {
        let preview = try JSONDecoder().decode(MoveToAutoCloudImport.Preview.self, from: Data(Self.preview.utf8))
        #expect(preview.already == 1)
        #expect(MoveToAutoCloudImport.previewLines(preview).contains(MoveToAutoCloudStrings.already(1)))
    }

    /// The real CLI's JSON, kept current by the Rust golden `the_move_card_json_matches_its_golden`
    /// (cmux-tui `cli/migrate_tests.rs`): the preview, apply's answer (passed and failed) and one
    /// step line decode with the card's types.
    @Test func theCLIsJSONDecodes() throws {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appending(path: "cmux-tui/crates/cmux-tui").path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent != root, "no repo root above \(#filePath)")
            root = parent
        }
        let data = try Data(contentsOf: root.appending(path: "cmux-tui/crates/cmux-tui/tests/data/migrate_move_card.json"))
        let golden = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        func part<T: Decodable>(_ key: String, as _: T.Type) throws -> T {
            let value = try #require(golden[key], "golden has no \(key)")
            return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let preview = try part("preview", as: MoveToAutoCloudImport.Preview.self)
        #expect(preview.moving == 2 && preview.names == ["app", "web"] && preview.already == 1)
        #expect(preview.carry == 1 && preview.left == 1 && preview.leftRows == ["Docker volumes: not copied"])
        #expect(try part("apply_answer", as: MoveToAutoCloudImport.Applied.self) == .init(moved: 2, left: 0, reason: nil))
        #expect(try part("apply_failed", as: MoveToAutoCloudImport.Applied.self)
            == .init(moved: 0, left: 2, reason: "create-machine ~/code/app: not signed in"))
        #expect(try part("apply_event", as: MoveToAutoCloudImport.Step.self).progress == 0.25)
    }
}
