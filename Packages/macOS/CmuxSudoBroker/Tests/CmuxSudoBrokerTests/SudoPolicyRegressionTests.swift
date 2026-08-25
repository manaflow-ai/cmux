@testable import CmuxSudoBroker
import Darwin
import Foundation
import Testing

@Suite("Sudo broker policies")
struct SudoPolicyRegressionTests {
    @Test("PAM parser requires an active sufficient pam_tid rule")
    func pamParser() {
        #expect(!SudoPAMConfiguration.containsEnabledEntry("#auth sufficient pam_tid.so\n"))
        #expect(SudoPAMConfiguration.containsEnabledEntry("auth   sufficient   pam_tid.so\n"))
        #expect(!SudoPAMConfiguration.containsEnabledEntry("auth required pam_tid.so\n"))
    }

    @Test("PAM reader accepts Touch ID from either sudo policy")
    func pamPolicyLocations() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let localURL = fixture.root.appendingPathComponent("sudo_local")
        let systemURL = fixture.root.appendingPathComponent("sudo")
        try Data("# auth sufficient pam_tid.so\n".utf8).write(to: localURL)
        try Data("auth sufficient pam_tid.so\n".utf8).write(to: systemURL)

        let configuration = SudoPAMConfiguration(fileURLs: [localURL, systemURL])

        #expect(configuration.touchIDIsEnabled())
    }

    @Test("CLI timeout distinguishes approved execution from pending approval")
    func phaseAwareCLITimeout() {
        #expect(SudoCLITimeoutDisposition.resolve(phase: nil) == .pendingApproval)
        #expect(SudoCLITimeoutDisposition.resolve(phase: .pendingApproval) == .pendingApproval)
        #expect(SudoCLITimeoutDisposition.resolve(phase: .approved) == .approvedExecution)
        #expect(SudoCLITimeoutDisposition.resolve(phase: .executing) == .approvedExecution)
    }

    @Test("Bundle scopes cannot escape the sudo spool root")
    func reservedBundleScopes() {
        let applicationSupport = URL(
            fileURLWithPath: "/tmp/cmux-sudo-policy-tests",
            isDirectory: true
        )
        for identifier in ["", ".", ".."] {
            let paths = SudoBrokerPaths(
                applicationSupportDirectory: applicationSupport,
                bundleIdentifier: identifier
            )
            #expect(paths.base.lastPathComponent == "com.cmuxterm.app")
            #expect(paths.base.deletingLastPathComponent().lastPathComponent == "sudo")
        }
    }

    @Test("Helper environment excludes unrelated inherited secrets")
    func helperEnvironmentAllowlist() {
        let environment = SudoProcessEnvironment(
            inherited: [
                "HOME": "/Users/test",
                "LC_MESSAGES": "ja_JP.UTF-8",
                "PATH": "/tmp/untrusted-bin",
                "SECRET_TOKEN": "do-not-forward",
            ]
        ).entries

        #expect(environment.contains("HOME=/Users/test"))
        #expect(environment.contains("LC_MESSAGES=ja_JP.UTF-8"))
        #expect(environment.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"))
        #expect(!environment.contains(where: { $0.hasPrefix("SECRET_TOKEN=") }))
    }

    @Test("Kevent timeout conversion clamps before integer conversion")
    func keventTimeoutClamping() {
        #expect(SudoKeventTimeout(seconds: -.infinity).milliseconds == 1)
        #expect(SudoKeventTimeout(seconds: 0.001).milliseconds == 1)
        #expect(SudoKeventTimeout(seconds: .infinity).milliseconds == Int.max)
        #expect(SudoKeventTimeout(seconds: .greatestFiniteMagnitude).milliseconds == Int.max)
    }

    @Test("Authentication detection ignores ordinary script output")
    func authenticationPromptOwnership() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let outputURL = fixture.paths.results.appendingPathComponent("auth-output.txt")
        let detector = SudoAuthenticationOutputDetector()

        try Data("Password: nested tool prompt\n".utf8).write(to: outputURL)
        #expect(!detector.indicatesPasswordPrompt(at: outputURL))

        try Data(SudoAuthenticationOutputDetector.passwordPrompt.utf8).write(to: outputURL)
        #expect(detector.indicatesPasswordPrompt(at: outputURL))
    }

    @Test("Authentication detection spans output chunks and strips its sentinel")
    func streamedAuthenticationPromptDetection() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let outputURL = fixture.paths.results.appendingPathComponent("streamed-auth.txt")
        let outputDescriptor = Darwin.open(
            outputURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(0o600)
        )
        try #require(outputDescriptor >= 0)
        var shouldClose = true
        defer {
            if shouldClose { Darwin.close(outputDescriptor) }
        }
        let controlMarkers = SudoExecutionControlMarkers()
        var collector = SudoExecutionOutputCollector(
            outputDescriptor: outputDescriptor,
            readinessMarker: nil,
            controlMarkers: controlMarkers
        )
        let marker = Data(SudoAuthenticationOutputDetector.passwordPrompt.utf8)
        let split = marker.count / 2

        try collector.consume(Data("before".utf8) + Data(marker.prefix(split)))
        #expect(!collector.authenticationFailed)
        try collector.consume(Data(marker.dropFirst(split)) + Data("after".utf8))
        try collector.finish()
        #expect(collector.authenticationFailed)
        #expect(Darwin.close(outputDescriptor) == 0)
        shouldClose = false

        let output = try Data(contentsOf: outputURL)
        #expect(output == Data("beforeafter".utf8))
    }

    @Test("Privileged timeout markers are stripped and preserved as control state")
    func privilegedTimeoutMarkerIsOutOfBand() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let outputURL = fixture.paths.results.appendingPathComponent("root-timeout.txt")
        let outputDescriptor = Darwin.open(
            outputURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(0o600)
        )
        try #require(outputDescriptor >= 0)
        defer { Darwin.close(outputDescriptor) }
        let controlMarkers = SudoExecutionControlMarkers()
        var collector = SudoExecutionOutputCollector(
            outputDescriptor: outputDescriptor,
            readinessMarker: nil,
            controlMarkers: controlMarkers
        )

        try collector.consume(
            Data("before".utf8)
                + controlMarkers.executionTimedOut
                + Data("after".utf8)
        )
        try collector.finish()

        #expect(collector.privilegedFailure == .privilegedTimedOut)
        #expect(try Data(contentsOf: outputURL) == Data("beforeafter".utf8))
    }

    @Test("Reviewed-script capability is anonymous and byte exact")
    func reviewedScriptCapability() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let reviewedScript = Data([0, 1, 2, 3, 0xff])
        let capability = SudoReviewedScriptCapability(
            bytes: reviewedScript,
            temporaryDirectoryURL: fixture.root
        )

        let captured = try capability.withDescriptor { descriptor in
            var status = stat()
            #expect(fstat(descriptor, &status) == 0)
            #expect(status.st_nlink == 0)
            return try SudoReviewedScriptReader(descriptor: descriptor).read()
        }

        #expect(captured == reviewedScript)
    }

    @Test("Orphan inventory rejects a PID generation that changes during argument capture")
    func orphanInventoryRejectsPIDReuseRace() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let approvedScriptURL = fixture.paths.approved
            .appendingPathComponent("pid-reuse.sh", isDirectory: false)
        let processIdentifier: Int32 = 4_242
        let initialIdentity = SudoProcessIdentity(
            processIdentifier: processIdentifier,
            startSeconds: 100,
            startMicroseconds: 10
        )
        let reusedIdentity = SudoProcessIdentity(
            processIdentifier: processIdentifier,
            startSeconds: 101,
            startMicroseconds: 20
        )
        let inspector = SequencedSudoProcessInspector(
            processIdentifier: processIdentifier,
            identities: [initialIdentity, reusedIdentity],
            arguments: [
                "/usr/bin/script", "-q", "/dev/null", "/usr/bin/sudo", "-k",
                "-p", SudoAuthenticationOutputDetector.passwordPrompt,
                "/bin/bash", approvedScriptURL.path,
            ]
        )

        let inventory = SudoOrphanProcessInventory(inspector: inspector)
            .identitiesByScriptPath(approvedScriptURLs: [approvedScriptURL])

        #expect(inventory[approvedScriptURL.standardizedFileURL.path]?.isEmpty == true)
    }

    @Test("Spool admission bounds pending approval state")
    func pendingAdmissionIsBounded() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let createdAt = Date.now

        for index in 0..<8 {
            _ = try fixture.enqueue(id: "bounded-pending-\(index)", createdAt: createdAt)
        }

        #expect(throws: (any Error).self) {
            _ = try fixture.enqueue(id: "bounded-pending-overflow", createdAt: createdAt)
        }
    }

    @Test("Bounded input stops reading an endless device at the caller limit")
    func endlessInputIsBounded() throws {
        let descriptor = Darwin.open("/dev/zero", O_RDONLY | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { Darwin.close(descriptor) }

        let data = try SudoBoundedInputReader().read(
            descriptor: descriptor,
            maximumBytes: 4_097
        )

        #expect(data.count == 4_097)
    }

    @Test("Spool maintenance removes abandoned terminal artifacts")
    func terminalArtifactRetentionIsBounded() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let id = "abandoned-terminal-artifacts"
        let archiveURL = fixture.paths.archive.appendingPathComponent("\(id).sh")
        let resultURL = fixture.paths.results.appendingPathComponent("\(id).json")
        let lockURL = fixture.paths.locks.appendingPathComponent("\(id).lock")
        let oldDate = Date.now.addingTimeInterval(-48 * 60 * 60)

        try Data("archived secret\n".utf8).write(to: archiveURL)
        _ = try fixture.store.writeResultIfAbsent(
            SudoResult(id: id, status: .completed, exitCode: 0)
        )
        try Data().write(to: lockURL)
        for url in [archiveURL, resultURL, lockURL] {
            try FileManager.default.setAttributes(
                [.modificationDate: oldDate],
                ofItemAtPath: url.path
            )
        }

        try fixture.store.ensureDirectories()

        #expect(!FileManager.default.fileExists(atPath: archiveURL.path))
        #expect(!FileManager.default.fileExists(atPath: resultURL.path))
        #expect(!FileManager.default.fileExists(atPath: lockURL.path))
    }

    @Test("Audit retention is bounded")
    func auditRetentionIsBounded() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let line = String(repeating: "a", count: 512)

        for _ in 0..<2_500 {
            fixture.store.appendAudit(line)
        }

        let size = try #require(
            FileManager.default.attributesOfItem(atPath: fixture.paths.auditLog.path)[.size]
                as? NSNumber
        )
        #expect(size.intValue <= 1_024 * 1_024)
    }

    @Test("Process-tree expansion inspects each generation a bounded number of times")
    func processTreeExpansionIsLinear() {
        let identities = (0..<100).map { index in
            SudoProcessIdentity(
                processIdentifier: Int32(10_000 + index),
                startSeconds: 1,
                startMicroseconds: Int32(index)
            )
        }
        let inspector = CountingSudoProcessInspector(chain: identities)
        let terminator = SudoProcessTreeTerminator(
            inspector: inspector,
            signaler: TestSudoProcessSignaler(),
            terminationGraceSeconds: 0,
            killGraceSeconds: 0
        )

        _ = terminator.terminate(root: identities[0])

        #expect(inspector.directChildQueryCount <= identities.count * 2)
    }
}
