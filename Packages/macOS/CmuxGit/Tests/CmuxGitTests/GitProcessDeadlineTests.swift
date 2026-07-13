import Darwin
import Foundation
import Testing

@testable import CmuxGit

@Suite struct GitProcessDeadlineTests {
    @Test func completedWatchdogCannotFire() {
        let pipe = Pipe()
        let watchdog = GitProcessWatchdog(
            process: Process(),
            processGroupIdentifier: Int32.max,
            outputHandle: pipe.fileHandleForReading
        )

        watchdog.cancelEscalation()
        watchdog.fire()

        #expect(!watchdog.didFire)
    }

    @Test func deadlineEscalatesWhenGitIgnoresTerminationAndChildKeepsPipeOpen() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let stalledGit = repo.appendingPathComponent("term-ignoring-git.sh")
        try Data("#!/bin/sh\ntrap '' TERM\nsleep 30 &\nwait\n".utf8).write(to: stalledGit)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stalledGit.path
        )

        let service = GitDiffService(
            gitExecutableURL: stalledGit,
            processDeadlineSeconds: 0.1
        )
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = service.repositoryRoot(for: repo.path)
            finished.signal()
        }

        #expect(finished.wait(timeout: .now() + 5) == .success)
    }

    @Test func deadlineKillsPipeHolderAfterGitLeaderExits() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let childPIDFile = repo.appendingPathComponent("orphan-child.pid")
        let exitedGit = repo.appendingPathComponent("exited-git-with-child.sh")
        try Data(
            "#!/bin/sh\n(trap '' TERM HUP; exec sleep 30) &\necho $! > \(childPIDFile.path.debugDescription)\nexit 0\n".utf8
        ).write(to: exitedGit)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: exitedGit.path
        )

        let service = GitDiffService(
            gitExecutableURL: exitedGit,
            processDeadlineSeconds: 1
        )
        let finished = DispatchSemaphore(value: 0)
        let box = DeadlineRootBox()
        DispatchQueue.global().async {
            box.value = service.repositoryRoot(for: repo.path)
            finished.signal()
        }
        var childPID: pid_t?
        var requestFinished = false
        defer {
            if let childPID, isExecutingProcess(childPID) {
                kill(childPID, SIGKILL)
            }
            if !requestFinished {
                _ = finished.wait(timeout: .now() + 5)
            }
        }

        let signalled = finished.wait(timeout: .now() + 5)
        requestFinished = signalled == .success
        #expect(signalled == .success)
        guard signalled == .success else { return }
        #expect(box.value == nil)
        let pidText = try String(contentsOf: childPIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let recordedPID = try #require(Int32(pidText))
        childPID = recordedPID
        #expect(!isExecutingProcess(recordedPID))
    }

    @Test func stalledGitProcessIsTerminatedAtTheDeadline() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let stalledGit = repo.appendingPathComponent("stalled-git.sh")
        try Data("#!/bin/sh\nsleep 30\n".utf8).write(to: stalledGit)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stalledGit.path
        )

        let service = GitDiffService(
            gitExecutableURL: stalledGit,
            processDeadlineSeconds: 0.5
        )
        let finished = DispatchSemaphore(value: 0)
        let box = DeadlineRootBox()
        DispatchQueue.global().async {
            box.value = service.repositoryRoot(for: repo.path)
            finished.signal()
        }
        let signalled = finished.wait(timeout: .now() + 5)
        #expect(signalled == .success)
        #expect(box.value == nil)
    }

    @Test func deadlineTerminatesDescendantsInTheGitProcessGroup() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let stalledGit = repo.appendingPathComponent("descendant-git.sh")
        let childPIDFile = repo.appendingPathComponent("child.pid")
        try Data(
            "#!/bin/sh\ntrap '' TERM\nsleep 30 &\necho $! > \(childPIDFile.path.debugDescription)\nwait\n".utf8
        ).write(to: stalledGit)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stalledGit.path
        )

        let service = GitDiffService(
            gitExecutableURL: stalledGit,
            processDeadlineSeconds: 5
        )
        #expect(service.repositoryRoot(for: repo.path) == nil)

        let pidText = try String(contentsOf: childPIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try #require(Int32(pidText))
        #expect(!isExecutingProcess(childPID))
    }

    private func makeTempRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-git-deadline-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for arguments in [
            ["init", "--quiet"],
            ["config", "user.email", "tests@cmux.dev"],
            ["config", "user.name", "cmux tests"],
            ["commit", "--allow-empty", "--quiet", "-m", "init"],
        ] {
            try runTestGit(in: root, arguments)
        }
        return root
    }

    private func runTestGit(in root: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    private func isExecutingProcess(_ processIdentifier: pid_t) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "state=", "-p", String(processIdentifier)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        let state = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        return state?.hasPrefix("Z") == false
    }
}
