import CmuxFoundation
import Foundation
import os
import Testing
@testable import CmuxTerminal

/// Installs into a directory the moment the sweep moves it aside, the way
/// another cmux restoring that surface between the sweep's two looks would.
private final class InstallDuringSweepFileManager: FileManager {
    private let installedDirectoryPath: String
    private let installer: AgentPIDProcessIdentity

    init(installedDirectoryURL: URL, installer: AgentPIDProcessIdentity) {
        self.installedDirectoryPath = installedDirectoryURL.path
        self.installer = installer
        super.init()
    }

    override func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        if sourceURL.path == installedDirectoryPath {
            TerminalSurfaceAgentCommandShimCleanup(
                rootDirectory: sourceURL.deletingLastPathComponent().deletingLastPathComponent(),
                owner: installer
            ).writeOwnerRecord(inDirectory: sourceURL)
            try setAttributes([.modificationDate: Date()], ofItemAtPath: sourceURL.path)
        }
        try super.moveItem(at: sourceURL, to: destinationURL)
    }
}

/// Publishes a directory under the name an install is about to move its own
/// to, the way another cmux restoring the same surface can between the
/// install's look and its move when the install could not get the lock.
private final class PublishRaceFileManager: FileManager {
    private let racedDirectoryPath: String
    private let raced = OSAllocatedUnfairLock(initialState: false)

    init(racedDirectoryURL: URL) {
        self.racedDirectoryPath = racedDirectoryURL.path
        super.init()
    }

    override func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        let isFirstPublish = raced.withLock { alreadyRaced in
            defer { alreadyRaced = true }
            return !alreadyRaced
        }
        if destinationURL.path == racedDirectoryPath, isFirstPublish {
            try createDirectory(at: destinationURL, withIntermediateDirectories: false)
            try Data("another cmux's shim\n".utf8)
                .write(to: destinationURL.appendingPathComponent("codex"))
        }
        try super.moveItem(at: sourceURL, to: destinationURL)
    }
}

/// Records, at every move, whether the shim directory lock is free. Installing
/// and sweeping both publish with a move, so this samples the moment they
/// could collide.
private final class LockProbingFileManager: FileManager {
    private let shimParentDirectory: URL
    private let observations = OSAllocatedUnfairLock<[Bool]>(initialState: [])

    init(shimParentDirectory: URL) {
        self.shimParentDirectory = shimParentDirectory
        super.init()
    }

    /// Whether the lock was free at each move, in order.
    var lockWasFreeAtEachMove: [Bool] {
        observations.withLock { $0 }
    }

    override func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        let free = TerminalSurfaceAgentCommandShimCleanup.DirectoryLock(
            shimParentDirectory: shimParentDirectory
        ) != nil
        observations.withLock { $0.append(free) }
        try super.moveItem(at: sourceURL, to: destinationURL)
    }
}

@Suite("Terminal surface command shim cleanup")
struct TerminalSurfaceAgentCommandShimCleanupTests {
    private let root: URL
    private let shimParent: URL
    private let now = Date()
    private let runningCmux = AgentPIDProcessIdentity(pid: 4_001, startSeconds: 1_000, startMicroseconds: 1)
    private let exitedCmux = AgentPIDProcessIdentity(pid: 4_002, startSeconds: 2_000, startMicroseconds: 2)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shim-cleanup-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        shimParent = root.appendingPathComponent("cmux-cli-shims", isDirectory: true)
        try FileManager.default.createDirectory(at: shimParent, withIntermediateDirectories: true)
    }

    private var cutoff: Date { now.addingTimeInterval(-24 * 60 * 60) }
    private var stale: Date { now.addingTimeInterval(-3 * 24 * 60 * 60) }

    /// Creates a shim directory holding one script and, with an `owner`, its
    /// record, all last written at `date`.
    @discardableResult
    private func makeShimDirectory(
        _ name: String,
        writtenAt date: Date,
        owner: AgentPIDProcessIdentity? = nil,
        alsoOwnedBy secondOwner: AgentPIDProcessIdentity? = nil
    ) throws -> URL {
        let directory = shimParent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("#!/bin/bash\n".utf8).write(to: directory.appendingPathComponent("codex"))
        for owner in [owner, secondOwner].compactMap({ $0 }) {
            #expect(cleanup(as: owner).writeOwnerRecord(inDirectory: directory))
        }
        try setLastWrite(date, of: directory)
        return directory
    }

    private func setLastWrite(_ date: Date, of directory: URL) throws {
        for entry in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            try FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: directory.appendingPathComponent(entry).path
            )
        }
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: directory.path)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// What the shim parent holds, apart from the lock file a sweep leaves.
    private func shimParentEntries() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: shimParent.path)).subtracting([".lock"])
    }

    /// A cleanup acting for `owner`, in a world where only `runningCmux` is alive.
    private func cleanup(
        as owner: AgentPIDProcessIdentity?,
        root cleanedRoot: URL? = nil,
        fileManager: FileManager = .default
    ) -> TerminalSurfaceAgentCommandShimCleanup {
        let runningCmux = runningCmux
        return TerminalSurfaceAgentCommandShimCleanup(
            rootDirectory: cleanedRoot ?? root,
            owner: owner,
            ownerIsRunning: { $0 == runningCmux },
            fileManager: fileManager
        )
    }

    /// Closes `surface`'s pane as `closingCmux`.
    private func close(_ surface: UUID, as closingCmux: AgentPIDProcessIdentity) -> Bool {
        cleanup(as: closingCmux).removeShimDirectory(surfaceId: surface)
    }

    private func owners(of directory: URL) -> Set<AgentPIDProcessIdentity> {
        Set(cleanup(as: nil).ownerRecords(inDirectory: directory))
    }

    private func sweep(
        root sweptRoot: URL? = nil,
        inUse: Set<String> = [],
        removesDirectoriesWithoutOwnerRecord: Bool = false,
        fileManager: FileManager = .default
    ) -> Set<String> {
        Set(
            cleanup(as: nil, root: sweptRoot, fileManager: fileManager).removeUnusedShimDirectories(
                inUseDirectoryNames: inUse,
                unusedSince: cutoff,
                removesDirectoriesWithoutOwnerRecord: removesDirectoriesWithoutOwnerRecord
            )
        )
    }

    @Test("A closed surface's directory is removed and its neighbours stay")
    func removesTheClosedSurfaceDirectory() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let closed = UUID()
        let open = UUID()
        let closedDirectory = try makeShimDirectory(closed.uuidString, writtenAt: now, owner: runningCmux)
        let openDirectory = try makeShimDirectory(open.uuidString, writtenAt: now, owner: runningCmux)

        let removed = close(closed, as: runningCmux)

        #expect(removed)
        #expect(!exists(closedDirectory))
        #expect(exists(openDirectory.appendingPathComponent("codex")))
    }

    @Test("A directory two cmux apps share goes only when the last of them closes it")
    func closingKeepsADirectoryAnotherCmuxStillUses() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // A session restored from another channel keeps its surface ids, so
        // both apps install into the same directory.
        let shared = UUID()
        let otherCmux = AgentPIDProcessIdentity(pid: 4_003, startSeconds: 3_000, startMicroseconds: 3)
        let directory = try makeShimDirectory(
            shared.uuidString,
            writtenAt: now,
            owner: runningCmux,
            alsoOwnedBy: otherCmux
        )

        let removedByFirstClose = close(shared, as: otherCmux)

        #expect(!removedByFirstClose)
        #expect(exists(directory.appendingPathComponent("codex")))
        #expect(owners(of: directory) == [runningCmux])

        let removedByLastClose = close(shared, as: runningCmux)

        #expect(removedByLastClose)
        #expect(!exists(directory))
    }

    @Test("Closing leaves a directory that no longer carries this cmux's record")
    func closingLeavesADirectoryReplacedSinceItsInstall() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // A cmux older than the records, holding the same restored surface,
        // installed over this one's directory and wiped its record.
        let replaced = UUID()
        let directory = try makeShimDirectory(replaced.uuidString, writtenAt: now)

        let removed = close(replaced, as: runningCmux)

        #expect(!removed)
        #expect(exists(directory.appendingPathComponent("codex")))
    }

    @Test("Closing does not wait for the lock, and leaves the directory to the sweep")
    func closingSkipsADirectoryWhileTheLockIsHeld() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let surface = UUID()
        let directory = try makeShimDirectory(surface.uuidString, writtenAt: now, owner: runningCmux)
        let heldElsewhere = try #require(
            TerminalSurfaceAgentCommandShimCleanup.DirectoryLock(shimParentDirectory: shimParent)
        )

        let removed = withExtendedLifetime(heldElsewhere) { close(surface, as: runningCmux) }

        #expect(!removed)
        #expect(exists(directory.appendingPathComponent("codex")))
    }

    @Test("Closing a surface never follows a symlink planted under its name")
    func leavesASymlinkedSurfaceDirectory() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let surface = UUID()
        let target = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let kept = target.appendingPathComponent("kept", isDirectory: false)
        try Data("kept".utf8).write(to: kept)
        let link = shimParent.appendingPathComponent(surface.uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let removed = close(surface, as: runningCmux)

        #expect(!removed)
        #expect(exists(kept))
    }

    @Test("Owner records read back as the processes written, and nothing else does")
    func ownerRecordsRoundTrip() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let recorded = try makeShimDirectory(
            UUID().uuidString,
            writtenAt: now,
            owner: runningCmux,
            alsoOwnedBy: exitedCmux
        )
        let unrecorded = try makeShimDirectory(UUID().uuidString, writtenAt: now)
        let malformed = try makeShimDirectory(UUID().uuidString, writtenAt: now)
        try Data("4001 not-a-number 1\n".utf8).write(to: malformed.appendingPathComponent(".owner.4001"))
        let oversized = try makeShimDirectory(UUID().uuidString, writtenAt: now)
        try Data(("4001 1000 1" + String(repeating: "\n", count: 200)).utf8)
            .write(to: oversized.appendingPathComponent(".owner.4001"))

        #expect(owners(of: recorded) == [runningCmux, exitedCmux])
        #expect(owners(of: unrecorded).isEmpty)
        #expect(owners(of: malformed).isEmpty)
        #expect(owners(of: oversized).isEmpty)
    }

    @Test("Installing shims records the installing process as their owner")
    func installRecordsTheInstallingProcess() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapperDirectory = root.appendingPathComponent("bundle-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapperDirectory, withIntermediateDirectories: false)
        let wrapper = wrapperDirectory.appendingPathComponent("cmux-codex-wrapper", isDirectory: false)
        try Data("#!/bin/bash\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let surface = UUID()

        let shims = try #require(
            TerminalSurface.installAgentCommandShimsIfPossible(
                wrapperDirectoryURL: wrapperDirectory,
                surfaceId: surface,
                rootDirectory: root
            )
        )

        let thisProcess = try #require(AgentPIDProcessIdentity(pid: getpid()))
        let installed = URL(fileURLWithPath: shims.directoryPath, isDirectory: true)
        #expect(owners(of: installed) == [thisProcess])

        // Another cmux that restored the same surface installed here too.
        // The process that started this test stands in for it: it is running.
        let otherCmux = try #require(AgentPIDProcessIdentity(pid: getppid()))
        // These cleanups ask the kernel who is running, as the app's do.
        let asOtherCmux = TerminalSurfaceAgentCommandShimCleanup(rootDirectory: root, owner: otherCmux)
        asOtherCmux.writeOwnerRecord(inDirectory: installed)
        TerminalSurfaceAgentCommandShimCleanup(rootDirectory: root, owner: exitedCmux)
            .writeOwnerRecord(inDirectory: installed)
        _ = try #require(
            TerminalSurface.installAgentCommandShimsIfPossible(
                wrapperDirectoryURL: wrapperDirectory,
                surfaceId: surface,
                rootDirectory: root
            )
        )
        // Reinstalling replaces the directory but keeps the claim of every
        // cmux that still runs, and drops the one that has exited.
        #expect(owners(of: installed) == [thisProcess, otherCmux])
        asOtherCmux.removeShimDirectory(surfaceId: surface)
        #expect(owners(of: installed) == [thisProcess])
        // The default check is the real one: this process is running, so its
        // directory survives a sweep however old it looks.
        try setLastWrite(stale, of: installed)
        let asThisProcess = TerminalSurfaceAgentCommandShimCleanup(rootDirectory: root)
        let removed = asThisProcess.removeUnusedShimDirectories(
            inUseDirectoryNames: [],
            unusedSince: cutoff,
            removesDirectoriesWithoutOwnerRecord: true
        )
        #expect(removed.isEmpty)
        #expect(exists(installed.appendingPathComponent("codex")))

        // The same pid with another start time is a process that has gone
        // and had its pid reused.
        let reusedPID = AgentPIDProcessIdentity(
            pid: thisProcess.pid,
            startSeconds: thisProcess.startSeconds - 1,
            startMicroseconds: thisProcess.startMicroseconds
        )
        let reusedDirectory = try makeShimDirectory(UUID().uuidString, writtenAt: stale, owner: reusedPID)
        let removedAfterReuse = asThisProcess.removeUnusedShimDirectories(
            inUseDirectoryNames: [],
            unusedSince: cutoff,
            removesDirectoriesWithoutOwnerRecord: false
        )
        #expect(removedAfterReuse == [reusedDirectory.lastPathComponent])
        #expect(exists(installed.appendingPathComponent("codex")))
    }

    /// A bundle directory holding one wrapper the installer will shim.
    private func makeWrapperDirectory() throws -> URL {
        let wrapperDirectory = root.appendingPathComponent("bundle-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapperDirectory, withIntermediateDirectories: false)
        let wrapper = wrapperDirectory.appendingPathComponent("cmux-codex-wrapper", isDirectory: false)
        try Data("#!/bin/bash\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        return wrapperDirectory
    }

    @Test("A directory taken over from a cmux that kept no record is left for the sweep")
    func installOverAnUnrecordedDirectoryKeepsItForItsOtherUser() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapperDirectory = try makeWrapperDirectory()
        // A cmux built before owner records has this pane open, and a session
        // restored from its channel gave this cmux the same surface.
        let shared = UUID()
        let directory = try makeShimDirectory(shared.uuidString, writtenAt: now)
        _ = try #require(
            TerminalSurface.installAgentCommandShimsIfPossible(
                wrapperDirectoryURL: wrapperDirectory,
                surfaceId: shared,
                rootDirectory: root
            )
        )
        let thisProcess = try #require(AgentPIDProcessIdentity(pid: getpid()))
        #expect(owners(of: directory) == [thisProcess])

        // Closing the pane here must not take the directory from the other cmux.
        let removedByClose = TerminalSurfaceAgentCommandShimCleanup(rootDirectory: root)
            .removeShimDirectory(surfaceId: shared)

        #expect(!removedByClose)
        #expect(exists(directory.appendingPathComponent("codex")))

        // Nor may a sweep, days after this cmux has gone, while another runs.
        try setLastWrite(stale, of: directory)
        let whileAnotherCmuxRuns = sweep(removesDirectoriesWithoutOwnerRecord: false)

        #expect(whileAnotherCmuxRuns.isEmpty)
        #expect(exists(directory.appendingPathComponent("codex")))

        let alone = sweep(removesDirectoriesWithoutOwnerRecord: true)

        #expect(alone == [shared.uuidString])
        #expect(!exists(directory))
    }

    @Test("Reinstalling keeps the claim of a cmux that kept no record")
    func reinstallKeepsTheUnrecordedClaim() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapperDirectory = try makeWrapperDirectory()
        let shared = UUID()
        let directory = try makeShimDirectory(shared.uuidString, writtenAt: now)
        for _ in 0..<2 {
            _ = try #require(
                TerminalSurface.installAgentCommandShimsIfPossible(
                    wrapperDirectoryURL: wrapperDirectory,
                    surfaceId: shared,
                    rootDirectory: root
                )
            )
        }

        let removedByClose = TerminalSurfaceAgentCommandShimCleanup(rootDirectory: root)
            .removeShimDirectory(surfaceId: shared)

        #expect(!removedByClose)
        #expect(exists(directory.appendingPathComponent("codex")))
    }

    @Test("An install that loses the race for its directory's name still publishes its shims")
    func installPublishesAgainAfterLosingTheRaceForItsDirectory() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapperDirectory = try makeWrapperDirectory()
        let restored = UUID()
        let directory = shimParent.appendingPathComponent(restored.uuidString, isDirectory: true)

        let shims = TerminalSurface.installAgentCommandShimsIfPossible(
            wrapperDirectoryURL: wrapperDirectory,
            surfaceId: restored,
            rootDirectory: root,
            fileManager: PublishRaceFileManager(racedDirectoryURL: directory)
        )

        #expect(shims?.directoryPath == directory.path)
        // This install's shim, not the directory that got there first.
        #expect(FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("codex").path))
        let thisProcess = try #require(AgentPIDProcessIdentity(pid: getpid()))
        #expect(owners(of: directory).contains(thisProcess))
    }

    @Test("Installing and sweeping take the same lock, so neither sees the other halfway")
    func installAndSweepPublishUnderOneLock() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapperDirectory = root.appendingPathComponent("bundle-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapperDirectory, withIntermediateDirectories: false)
        let wrapper = wrapperDirectory.appendingPathComponent("cmux-codex-wrapper", isDirectory: false)
        try Data("#!/bin/bash\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let orphaned = try makeShimDirectory(UUID().uuidString, writtenAt: stale, owner: exitedCmux)

        let installing = LockProbingFileManager(shimParentDirectory: shimParent)
        let shims = TerminalSurface.installAgentCommandShimsIfPossible(
            wrapperDirectoryURL: wrapperDirectory,
            surfaceId: UUID(),
            rootDirectory: root,
            fileManager: installing
        )
        let sweeping = LockProbingFileManager(shimParentDirectory: shimParent)
        let removed = sweep(fileManager: sweeping)

        #expect(shims != nil)
        #expect(removed == [orphaned.lastPathComponent])
        #expect(installing.lockWasFreeAtEachMove == [false])
        #expect(sweeping.lockWasFreeAtEachMove == [false])
        // Released afterwards: the next install or sweep does not wait.
        #expect(TerminalSurfaceAgentCommandShimCleanup.DirectoryLock(shimParentDirectory: shimParent) != nil)
    }

    @Test("The sweep removes stale directories whose installer has exited")
    func sweepRemovesDirectoriesOfAnExitedCmux() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let orphaned = UUID().uuidString
        let open = UUID().uuidString
        let named = UUID().uuidString
        let recent = UUID().uuidString
        let rewritten = UUID().uuidString
        let staging = ".\(UUID().uuidString).staging.\(UUID().uuidString)"
        let interruptedSweep = ".sweep.\(UUID().uuidString)"
        let orphanedDirectory = try makeShimDirectory(orphaned, writtenAt: stale, owner: exitedCmux)
        // An idle pane of a cmux that is still running: nothing has written
        // to it for days and no process shows it in its environment.
        let openDirectory = try makeShimDirectory(open, writtenAt: stale, owner: runningCmux)
        // A tmux server that outlived the cmux it was started from.
        let namedDirectory = try makeShimDirectory(named, writtenAt: stale, owner: exitedCmux)
        let recentDirectory = try makeShimDirectory(recent, writtenAt: now, owner: exitedCmux)
        // Shared with a cmux that has exited; the other one still runs.
        let shared = UUID().uuidString
        let sharedDirectory = try makeShimDirectory(
            shared,
            writtenAt: stale,
            owner: exitedCmux,
            alsoOwnedBy: runningCmux
        )
        let stagingDirectory = try makeShimDirectory(staging, writtenAt: stale)
        let interruptedSweepDirectory = try makeShimDirectory(interruptedSweep, writtenAt: stale)
        // Another cmux installing or sweeping right now.
        let installInFlight = ".\(UUID().uuidString).staging.\(UUID().uuidString)"
        let sweepInFlight = ".sweep.\(UUID().uuidString)"
        let installInFlightDirectory = try makeShimDirectory(installInFlight, writtenAt: now)
        let sweepInFlightDirectory = try makeShimDirectory(sweepInFlight, writtenAt: now)
        let unmanagedDirectory = try makeShimDirectory("notes", writtenAt: stale, owner: exitedCmux)
        // A shell integration rewrites `claude` in place: the script is new,
        // the directory's own date is not.
        let rewrittenDirectory = try makeShimDirectory(rewritten, writtenAt: stale, owner: exitedCmux)
        let rewrittenScript = rewrittenDirectory.appendingPathComponent("claude", isDirectory: false)
        try Data("#!/bin/bash\n".utf8).write(to: rewrittenScript)
        try FileManager.default.setAttributes(
            [.modificationDate: stale],
            ofItemAtPath: rewrittenDirectory.path
        )

        let removed = sweep(inUse: [named])

        #expect(removed == [orphaned, staging, interruptedSweep])
        #expect(!exists(orphanedDirectory))
        #expect(!exists(stagingDirectory))
        #expect(!exists(interruptedSweepDirectory))
        #expect(exists(openDirectory.appendingPathComponent("codex")))
        #expect(exists(namedDirectory.appendingPathComponent("codex")))
        #expect(exists(recentDirectory.appendingPathComponent("codex")))
        #expect(exists(sharedDirectory.appendingPathComponent("codex")))
        #expect(exists(rewrittenScript))
        #expect(exists(unmanagedDirectory.appendingPathComponent("codex")))
        #expect(exists(installInFlightDirectory.appendingPathComponent("codex")))
        #expect(exists(sweepInFlightDirectory.appendingPathComponent("codex")))
        #expect(
            try shimParentEntries()
                == [open, named, recent, shared, rewritten, "notes", installInFlight, sweepInFlight]
        )
    }

    @Test("Directories with no owner record go only when no other cmux can be using them")
    func sweepTreatsUnrecordedDirectoriesByWhetherAnotherCmuxRuns() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let olderBuild = UUID().uuidString
        let olderBuildDirectory = try makeShimDirectory(olderBuild, writtenAt: stale)
        let shellProcessDirectory = try makeShimDirectory("4242", writtenAt: stale)
        let recentDirectory = try makeShimDirectory(UUID().uuidString, writtenAt: now)

        let whileAnotherCmuxRuns = sweep(removesDirectoriesWithoutOwnerRecord: false)

        #expect(whileAnotherCmuxRuns.isEmpty)
        #expect(exists(olderBuildDirectory.appendingPathComponent("codex")))
        #expect(exists(shellProcessDirectory.appendingPathComponent("codex")))

        let alone = sweep(removesDirectoriesWithoutOwnerRecord: true)

        #expect(alone == [olderBuild, "4242"])
        #expect(!exists(olderBuildDirectory))
        #expect(!exists(shellProcessDirectory))
        #expect(exists(recentDirectory.appendingPathComponent("codex")))
    }

    @Test("The sweep leaves symlinks and files alone, whatever their names")
    func sweepLeavesSymlinksAndFiles() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let kept = target.appendingPathComponent("kept", isDirectory: false)
        try Data("kept".utf8).write(to: kept)
        try setLastWrite(stale, of: target)
        let link = shimParent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        // The link itself is as old as anything the sweep removes; its date
        // must not be what saves it.
        var staleTimes = [timeval](
            repeating: timeval(tv_sec: Int(stale.timeIntervalSince1970), tv_usec: 0),
            count: 2
        )
        #expect(lutimes(link.path, &staleTimes) == 0)
        let file = shimParent.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try Data("not a directory".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: stale], ofItemAtPath: file.path)

        let removed = sweep(removesDirectoriesWithoutOwnerRecord: true)

        #expect(removed.isEmpty)
        #expect(exists(kept))
        #expect(exists(file))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
    }

    @Test("A directory installed into while the sweep runs is put back")
    func sweepKeepsADirectoryInstalledIntoMidSweep() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let restored = UUID().uuidString
        let restoredDirectory = try makeShimDirectory(restored, writtenAt: stale, owner: exitedCmux)
        let untouched = UUID().uuidString
        let untouchedDirectory = try makeShimDirectory(untouched, writtenAt: stale, owner: exitedCmux)

        let removed = sweep(
            fileManager: InstallDuringSweepFileManager(
                installedDirectoryURL: restoredDirectory,
                installer: runningCmux
            )
        )

        #expect(removed == [untouched])
        #expect(!exists(untouchedDirectory))
        #expect(exists(restoredDirectory.appendingPathComponent("codex")))
        #expect(owners(of: restoredDirectory).contains(runningCmux))
        #expect(try shimParentEntries() == [restored])
    }

    @Test("A missing or symlinked shim root is left alone")
    func sweepIgnoresAnUnsafeRoot() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let staleDirectory = try makeShimDirectory(UUID().uuidString, writtenAt: stale, owner: exitedCmux)
        let linkedRoot = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedRoot, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: linkedRoot.appendingPathComponent("cmux-cli-shims", isDirectory: true),
            withDestinationURL: shimParent
        )

        let throughLink = sweep(root: linkedRoot, removesDirectoriesWithoutOwnerRecord: true)
        let missing = sweep(
            root: root.appendingPathComponent("absent", isDirectory: true),
            removesDirectoriesWithoutOwnerRecord: true
        )

        #expect(throughLink.isEmpty)
        #expect(missing.isEmpty)
        #expect(exists(staleDirectory.appendingPathComponent("codex")))
    }
}
