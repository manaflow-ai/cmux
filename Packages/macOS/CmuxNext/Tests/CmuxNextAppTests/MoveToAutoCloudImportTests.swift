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
        private(set) var calls: [[String]] = []

        func run(_ arguments: [String], _ timeout: Duration) throws -> MoveToAutoCloudImport.Ran {
            calls.append(arguments)
            if arguments.prefix(2) == ["migrate", "plan"], let out = arguments.firstIndex(of: "--out") {
                try Data("{}".utf8).write(to: URL(fileURLWithPath: arguments[out + 1]))
                return .init(status: 0, output: Data(preview.utf8), reason: "")
            }
            return .init(status: applyStatus, reason: applyStatus == 0 ? "" : "not signed in")
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
        let move = MoveToAutoCloudImport(cli: { try cli.run($0, $1) }, confirm: { shown = $0; return true }, folder: folder)
        let moved = try await move.run { progress.append($0) }
        #expect(moved == 2)
        #expect(shown?.names == ["app", "web"])
        #expect(cli.calls.count == 2)
        let file = try #require(cli.calls.first?[4])
        #expect(cli.calls[0] == ["migrate", "plan", "laptop", "--out", file, "--preview", "--json"])
        #expect(cli.calls[1] == ["migrate", "apply", file])
        #expect(progress == [1])
        // The plan file is the run's own and goes with it.
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @Test func declinedPreviewAppliesNothing() async throws {
        let cli = CLI()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let move = MoveToAutoCloudImport(cli: { try cli.run($0, $1) }, confirm: { _ in false }, folder: folder)
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
        let move = MoveToAutoCloudImport(cli: { try cli.run($0, $1) }, confirm: { _ in asked = true; return true }, folder: folder)
        #expect(try await move.run() == nil)
        #expect(!asked && cli.calls.count == 1)
    }

    @Test func aFailedApplyThrowsItsReason() async throws {
        let cli = CLI()
        cli.applyStatus = 1
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let move = MoveToAutoCloudImport(cli: { try cli.run($0, $1) }, confirm: { _ in true }, folder: folder)
        await #expect(throws: MoveToAutoCloudFailure.apply("not signed in")) { try await move.run() }
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
}
