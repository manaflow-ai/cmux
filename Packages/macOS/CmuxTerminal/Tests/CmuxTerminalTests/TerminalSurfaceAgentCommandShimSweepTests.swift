import CmuxFoundation
import Foundation
import Testing
@testable import CmuxTerminal

@Suite("Terminal surface command shim sweep")
struct TerminalSurfaceAgentCommandShimSweepTests {
    private typealias Sweep = TerminalSurfaceAgentCommandShimSweep

    private let root: URL
    private let shimParent: URL
    private let now = Date()
    private let exitedCmux = AgentPIDProcessIdentity(pid: 4_002, startSeconds: 2_000, startMicroseconds: 2)
    private let cmuxBundle = "/Users/me/DerivedData/cmux DEV tag.app"

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shim-sweep-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        shimParent = root.appendingPathComponent("cmux-cli-shims", isDirectory: true)
        try FileManager.default.createDirectory(at: shimParent, withIntermediateDirectories: true)
    }

    private var stale: Date { now.addingTimeInterval(-3 * 24 * 60 * 60) }

    /// Creates a shim directory last written at `date`, installed by a cmux
    /// that has exited unless `recordsOwner` is false.
    @discardableResult
    private func makeShimDirectory(
        _ name: String = UUID().uuidString,
        writtenAt date: Date,
        recordsOwner: Bool = true
    ) throws -> URL {
        let directory = shimParent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("#!/bin/bash\n".utf8).write(to: directory.appendingPathComponent("codex"))
        if recordsOwner {
            #expect(
                TerminalSurfaceAgentCommandShimCleanup(rootDirectory: root, owner: exitedCmux)
                    .writeOwnerRecord(inDirectory: directory)
            )
        }
        for entry in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            try FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: directory.appendingPathComponent(entry).path
            )
        }
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: directory.path)
        return directory
    }

    private func exists(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("codex").path)
    }

    /// The sweeping app itself: a cmux whose own environment can be read.
    private var thisProcess: Sweep.RunningProcess {
        process(10, name: "cmux DEV", path: "\(cmuxBundle)/Contents/MacOS/cmux DEV")
    }

    private func process(
        _ processID: Int,
        name: String = "node",
        path: String? = "/opt/homebrew/bin/node",
        environment: [String]? = ["/usr/bin:/bin"]
    ) -> Sweep.RunningProcess {
        Sweep.RunningProcess(
            processID: processID,
            name: name,
            executablePath: path,
            environmentValues: environment
        )
    }

    /// Sweeps as process 10, with no recorded owner still running and a
    /// wrapper in `cmuxBundle` only.
    private func sweep(
        _ processes: [Sweep.RunningProcess],
        isComplete: Bool = true,
        unusedLifetime: TimeInterval? = nil
    ) -> Sweep.Outcome {
        let cleanup = TerminalSurfaceAgentCommandShimCleanup(
            rootDirectory: root,
            owner: nil,
            ownerIsRunning: { _ in false }
        )
        let wrapper = "\(cmuxBundle)/Contents/Resources/bin/cmux-claude-wrapper"
        let table = Sweep.ProcessTable(processes: processes, isComplete: isComplete)
        let sweep = if let unusedLifetime {
            Sweep(
                cleanup: cleanup,
                unusedLifetime: unusedLifetime,
                currentProcessID: 10,
                processTable: { table },
                fileExists: { $0 == wrapper }
            )
        } else {
            Sweep(
                cleanup: cleanup,
                currentProcessID: 10,
                processTable: { table },
                fileExists: { $0 == wrapper }
            )
        }
        return sweep.sweep(now: now)
    }

    @Test("A directory a process still has on PATH or in a wrapper variable is kept")
    func keepsDirectoriesRunningProcessesName() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let onPath = try makeShimDirectory(writtenAt: stale)
        let inWrapperVariable = try makeShimDirectory(writtenAt: stale)
        let shellProcessFallback = try makeShimDirectory("4242", writtenAt: stale)
        let unnamed = try makeShimDirectory(writtenAt: stale)

        let outcome = sweep([
            thisProcess,
            process(20, environment: ["\(shimParent.path)/\(onPath.lastPathComponent):/usr/bin:/bin"]),
            process(30, environment: [
                "/elsewhere/cmux-cli-shims/\(inWrapperVariable.lastPathComponent)/claude",
                "/usr/bin:/var/folders/x/T/cmux-cli-shims/4242:/bin",
                // Neither of these names a directory.
                "\(shimParent.path)/",
                shimParent.path,
            ]),
            // A system binary such as zsh: its environment cannot be read.
            process(40, name: "zsh", path: "/bin/zsh", environment: nil),
        ])

        #expect(
            outcome == .swept(
                removed: [unnamed.lastPathComponent],
                namedByProcesses: 3,
                anotherCmuxIsRunning: false
            )
        )
        #expect(!exists(unnamed))
        #expect(exists(onPath))
        #expect(exists(inWrapperVariable))
        #expect(exists(shellProcessFallback))
    }

    @Test("Nothing is removed when the process table cannot be trusted")
    func skipsWithoutATrustworthyProcessTable() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let orphaned = try makeShimDirectory(writtenAt: stale)
        let unreadableSelf = process(
            10,
            name: "cmux DEV",
            path: "\(cmuxBundle)/Contents/MacOS/cmux DEV",
            environment: nil
        )

        let truncated = sweep([thisProcess, process(20)], isComplete: false)
        let blind = sweep([unreadableSelf, process(20)])

        #expect(truncated == .skippedUnreadableProcessTable)
        #expect(blind == .skippedUnreadableProcessTable)
        #expect(exists(orphaned))

        let trusted = sweep([thisProcess, process(20)])

        #expect(
            trusted == .swept(
                removed: [orphaned.lastPathComponent],
                namedByProcesses: 0,
                anotherCmuxIsRunning: false
            )
        )
        #expect(!exists(orphaned))
    }

    @Test("A directory with no owner record is kept while another cmux app runs")
    func keepsUnrecordedDirectoriesWhileAnotherCmuxRuns() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(what: String, others: [Sweep.RunningProcess], anotherCmuxIsRunning: Bool)] = [
            (
                "the stable app",
                [process(20, name: "zsh", path: "/bin/zsh"),
                 process(21, name: "cmux", path: "/Applications/cmux.app/Contents/MacOS/cmux")],
                true
            ),
            (
                "an app that ships the wrappers, whatever its executable is called",
                [process(20, name: "renamed", path: "\(cmuxBundle)/Contents/MacOS/renamed")],
                true
            ),
            (
                "a cmux whose bundle was replaced under it, so the kernel no longer places it",
                [process(20, name: "cmux DEV", path: nil)],
                true
            ),
            (
                "another app",
                [process(20, name: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari")],
                false
            ),
            (
                "the cmux CLI and a helper inside a cmux bundle",
                [process(20, name: "cmux", path: "\(cmuxBundle)/Contents/Resources/bin/cmux"),
                 process(21, name: "cmux-helper", path: "\(cmuxBundle)/Contents/MacOS/helpers/cmux-helper")],
                false
            ),
            (
                "the Computer Use helper, placed or not",
                [process(
                    20,
                    name: "cmux-cua",
                    path: "/Users/me/Library/cmux-cua/cmux Computer Use.app/Contents/MacOS/cmux-cua"
                 ),
                 process(21, name: "cmux-cua", path: nil)],
                false
            ),
            (
                "other processes the kernel cannot place",
                [process(20, name: "postgres", path: nil), process(21, name: "Cursor Helper", path: nil)],
                false
            ),
            ("no other process: the sweeping cmux does not count", [], false),
        ]

        for testCase in cases {
            let unrecorded = try makeShimDirectory(writtenAt: stale, recordsOwner: false)

            let outcome = sweep([thisProcess] + testCase.others)

            #expect(
                outcome == .swept(
                    removed: testCase.anotherCmuxIsRunning ? [] : [unrecorded.lastPathComponent],
                    namedByProcesses: 0,
                    anotherCmuxIsRunning: testCase.anotherCmuxIsRunning
                ),
                "\(testCase.what)"
            )
            #expect(exists(unrecorded) == testCase.anotherCmuxIsRunning, "\(testCase.what)")
            try? FileManager.default.removeItem(at: unrecorded)
        }
    }

    @Test("A directory is kept for the unused lifetime after its last write")
    func keepsDirectoriesWithinTheUnusedLifetime() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let twoHoursOld = try makeShimDirectory(writtenAt: now.addingTimeInterval(-2 * 60 * 60))

        let withTheDefaultDay = sweep([thisProcess])

        #expect(withTheDefaultDay == .swept(removed: [], namedByProcesses: 0, anotherCmuxIsRunning: false))
        #expect(exists(twoHoursOld))

        let withOneHour = sweep([thisProcess], unusedLifetime: 60 * 60)

        #expect(
            withOneHour == .swept(
                removed: [twoHoursOld.lastPathComponent],
                namedByProcesses: 0,
                anotherCmuxIsRunning: false
            )
        )
        #expect(!exists(twoHoursOld))
    }
}
