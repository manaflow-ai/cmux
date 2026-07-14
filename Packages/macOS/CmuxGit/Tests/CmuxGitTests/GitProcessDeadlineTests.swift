import Darwin
import Foundation
import Testing

@testable import CmuxGit

@Suite struct GitProcessDeadlineTests {
    private var processRunner: GitProcessRunner {
        GitProcessRunner(
            gitExecutableURL: URL(fileURLWithPath: "/usr/bin/git"),
            fileSystemStatExecutableURL: URL(fileURLWithPath: "/usr/bin/stat"),
            environment: ProcessInfo.processInfo.environment,
            processDeadlineSeconds: 1,
            processLifecycle: GitProcessLifecycleService()
        )
    }

    @Test func postSIGKILLWaitUsesFinalReapDeadline() {
        let plan = GitProcessWaitPlan(
            processDeadline: 10,
            escalationDeadline: 5,
            didSendSIGKILL: true,
            finalReapDeadline: 7
        )

        #expect(plan.deadline == 7)
    }

    @Test func outputCapTerminationProofIsMonotonic() {
        var state = GitOutputCapTerminationState()

        state.record(didSignalLiveProcess: true)
        state.record(didSignalLiveProcess: false)

        #expect(state.didTerminateForOutputCap)
    }

    @Test func subprocessClosesUnspecifiedInheritedDescriptors() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let sentinel = repo.appendingPathComponent("parent-only-descriptor")
        try Data().write(to: sentinel)
        let inheritedDescriptor = open(sentinel.path, O_RDONLY)
        try #require(inheritedDescriptor > STDERR_FILENO)
        defer { close(inheritedDescriptor) }
        let descriptorFlags = fcntl(inheritedDescriptor, F_GETFD)
        try #require(descriptorFlags >= 0)
        try #require(fcntl(inheritedDescriptor, F_SETFD, descriptorFlags & ~FD_CLOEXEC) == 0)

        let marker = repo.appendingPathComponent("inherited-descriptor-marker")
        let checkingGit = repo.appendingPathComponent("checking-descriptor-git.sh")
        let script = """
        #!/bin/sh
        if [ -e "/dev/fd/$CMUX_TEST_DESCRIPTOR" ]; then
            : > "$CMUX_TEST_MARKER"
        fi
        printf '%s\\n' "$2"
        """
        try Data(script.utf8).write(to: checkingGit)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: checkingGit.path
        )
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_TEST_DESCRIPTOR"] = String(inheritedDescriptor)
        environment["CMUX_TEST_MARKER"] = marker.path

        let root = GitDiffService(
            gitExecutableURL: checkingGit,
            environment: environment
        ).repositoryRoot(for: repo.path)

        #expect(root == repo.path)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
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
        let clock = ContinuousClock()
        let start = clock.now
        #expect(service.repositoryRoot(for: repo.path) == nil)
        #expect(start.duration(to: clock.now) < .seconds(5))
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
        var childPID: pid_t?
        defer {
            if let childPID, isExecutingProcess(childPID) {
                kill(childPID, SIGKILL)
            }
        }

        let clock = ContinuousClock()
        let start = clock.now
        #expect(service.repositoryRoot(for: repo.path) == nil)
        #expect(start.duration(to: clock.now) < .seconds(5))
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
        let clock = ContinuousClock()
        let start = clock.now
        #expect(service.repositoryRoot(for: repo.path) == nil)
        #expect(start.duration(to: clock.now) < .seconds(5))
    }

    @Test func failureWinsWhenSupervisedResultIsAlsoCapped() {
        let result = processRunner.translateSupervisedResult(
            GitProcessResult(
                rawOutput: Data(repeating: 0x78, count: 32),
                output: nil,
                capped: true,
                failure: .timedOut,
                terminationStatus: SIGKILL
            ),
            acceptedTerminationStatuses: [0],
            maxOutputBytes: 32
        )

        #expect(result.timedOut)
        #expect(!result.capped)
    }

    @Test func unsuccessfulExitWinsWhenSupervisedResultIsAlsoCapped() {
        let result = processRunner.translateSupervisedResult(
            GitProcessResult(
                rawOutput: Data(repeating: 0x78, count: 32),
                output: nil,
                capped: true,
                terminationStatus: 2
            ),
            acceptedTerminationStatuses: [0],
            maxOutputBytes: 32
        )

        #expect(result.failure == .unsuccessfulExit)
        #expect(!result.capped)
    }

    @Test func deadlineDoesNotDependOnAvailableDispatchWorkers() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let stalledGit = repo.appendingPathComponent("dispatch-saturated-git.sh")
        try Data("#!/bin/sh\nsleep 3\n".utf8).write(to: stalledGit)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stalledGit.path
        )

        let blockerCount = max(8, ProcessInfo.processInfo.activeProcessorCount * 2)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        for _ in 0..<blockerCount {
            DispatchQueue.global(qos: .userInitiated).async {
                started.signal()
                release.wait()
                finished.signal()
            }
        }
        defer {
            for _ in 0..<blockerCount { release.signal() }
            for _ in 0..<blockerCount {
                _ = finished.wait(timeout: .now() + 5)
            }
        }
        let requiredStartedCount = min(blockerCount, ProcessInfo.processInfo.activeProcessorCount)
        for _ in 0..<requiredStartedCount {
            try #require(started.wait(timeout: .now() + 2) == .success)
        }

        let service = GitDiffService(
            gitExecutableURL: stalledGit,
            processDeadlineSeconds: 0.1
        )
        let clock = ContinuousClock()
        let start = clock.now
        #expect(service.repositoryRoot(for: repo.path) == nil)
        #expect(start.duration(to: clock.now) < .seconds(2))
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

    @Test func outstandingDetachedReapBlocksNewLaunchesWithinBound() throws {
        let childPID = try #require(spawnSleepingProcess())
        defer { kill(childPID, SIGKILL) }

        let lifecycle = GitProcessLifecycleService(maxProcesses: 2)
        let firstPermit = try #require(lifecycle.beginProcess())
        let secondPermit = try #require(lifecycle.beginProcess())
        #expect(lifecycle.beginProcess() == nil)

        lifecycle.transferToDetachedReaper(
            firstPermit,
            processIdentifier: childPID
        )
        lifecycle.finishProcess(secondPermit)

        #expect(lifecycle.beginProcess() == nil)
    }

    private func spawnSleepingProcess() -> pid_t? {
        let executable = "/bin/sleep"
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        var processIdentifier: pid_t = 0
        let status = withCStringArray([executable, "30"]) { arguments in
            withCStringArray(environment) { environment in
                executable.withCString { path in
                    posix_spawn(
                        &processIdentifier,
                        path,
                        nil,
                        nil,
                        arguments,
                        environment
                    )
                }
            }
        }
        return status == 0 && processIdentifier > 0 ? processIdentifier : nil
    }

    private func withCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
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
