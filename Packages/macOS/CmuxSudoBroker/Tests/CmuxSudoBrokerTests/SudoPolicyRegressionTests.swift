@testable import CmuxSudoBroker
import CryptoKit
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

    @Test("Marker matcher preserves the earliest overlapping marker")
    func markerMatcherChoosesEarliestStart() {
        let matcher = SudoExecutionMarkerMatcher(
            markers: [
                (bytes: Array("abcd".utf8), kind: .authentication),
                (bytes: Array("bc".utf8), kind: .readiness),
            ]
        )

        let result = matcher.scan(
            ArraySlice(Array("xabcd".utf8)),
            isFinal: true
        )

        #expect(result.match?.offset == 1)
        #expect(result.match?.markerIndex == 0)
    }

    @Test("A complete authentication marker is reported without trailing output")
    func markerMatcherReportsCompleteAuthenticationMarkerImmediately() {
        let controlMarkers = SudoExecutionControlMarkers(token: String(repeating: "a", count: 36))
        let authenticationMarker = Array(SudoAuthenticationOutputDetector.passwordPrompt.utf8)
        let matcher = SudoExecutionMarkerMatcher(
            markers: [
                (bytes: authenticationMarker, kind: .authentication),
                (bytes: Array(controlMarkers.executionTimedOut), kind: .privilegedTimeout),
            ]
        )
        let output = ArraySlice([UInt8(ascii: "^"), UInt8(ascii: "D"), 0x08, 0x08] + authenticationMarker)

        let result = matcher.scan(output, isFinal: false)

        #expect(result.match?.offset == 4)
        #expect(result.match?.markerIndex == 0)
        #expect(result.retainedSuffixLength == 0)
    }

    @Test("Exit waiter handles reused PID generations without trapping")
    func exitWaiterHandlesDuplicatePIDGenerations() {
        let first = SudoProcessIdentity(
            processIdentifier: 7_777,
            startSeconds: 10,
            startMicroseconds: 1
        )
        let second = SudoProcessIdentity(
            processIdentifier: 7_777,
            startSeconds: 11,
            startMicroseconds: 2
        )
        let inspector = TestSudoProcessInspector(runningIdentities: Set([first, second]))
        let waiter = SudoProcessExitWaiter(inspector: inspector)

        let survivors = waiter.survivors(among: [first, second], after: 0)

        #expect(survivors.count == 1)
        #expect(survivors.first == second)
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

    @Test("Filesystem discovery applies pending request count and byte bounds")
    func pendingDiscoveryHonorsResourcePolicy() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let writer = SudoSpoolStore(
            paths: fixture.paths,
            resourcePolicy: SudoResourcePolicy(
                maximumPendingRequestCount: 8,
                maximumPendingScriptBytes: 2 * 1_024 * 1_024
            )
        )
        for index in 0..<4 {
            let request = SudoRequest(
                id: "discovery-\(index)",
                reason: "test",
                requesterIdentity: SudoTestFixture.defaultRequesterIdentity,
                requesterCommand: "test-agent",
                currentDirectory: "/tmp",
                createdAt: .now
            )
            try writer.enqueue(
                SudoPendingRequest(
                    request: request,
                    script: String(repeating: "x", count: 10)
                )
            )
        }
        let bounded = SudoSpoolStore(
            paths: fixture.paths,
            resourcePolicy: SudoResourcePolicy(
                maximumPendingRequestCount: 2,
                maximumPendingScriptBytes: 25
            )
        )

        let snapshots = bounded.pendingRequests()

        #expect(snapshots.map(\.request.id) == ["discovery-0", "discovery-1"])
        #expect(snapshots.reduce(0) { $0 + $1.script.utf8.count } <= 25)
    }

    @Test("A preexisting result cannot settle a live request")
    func preexistingResultIsNotAuthoritative() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let request = try fixture.enqueue(id: "preexisting-result", createdAt: .now)
        _ = try fixture.store.writeResultIfAbsent(
            SudoResult(id: request.id, status: .completed, exitCode: 0)
        )

        #expect(fixture.store.authoritativeResult(id: request.id) == nil)
        #expect(fixture.store.pendingRequests().map(\.request.id) == [request.id])
        do {
            _ = try fixture.store.settle(
                SudoResult(
                    id: request.id,
                    status: .failed,
                    errorCode: .requesterUnavailable
                )
            )
            Issue.record("Expected a preexisting live result to be rejected")
        } catch SudoSpoolError.resultAlreadyExists {
            // Expected: a live request cannot trust an unrelated result writer.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let boundedStore = SudoSpoolStore(
            paths: fixture.paths,
            resourcePolicy: SudoResourcePolicy(
                maximumPendingRequestCount: 1,
                maximumPendingScriptBytes: 1_024
            )
        )
        let secondRequest = SudoRequest(
            id: "preexisting-result-second",
            reason: "test",
            requesterIdentity: SudoTestFixture.defaultRequesterIdentity,
            requesterCommand: "test-agent",
            currentDirectory: "/tmp",
            createdAt: .now
        )
        do {
            try boundedStore.enqueue(
                SudoPendingRequest(request: secondRequest, script: "echo second\n")
            )
            Issue.record("Expected the pending-request capacity limit to reject the second request")
        } catch SudoSpoolError.requestCapacityExceeded {
            // Expected: the configured one-request admission bound is enforced.
        } catch {
            Issue.record("Unexpected admission error: \(error)")
        }
    }

    @Test("Spool startup completes a partially archived terminal result")
    func partialSettlementIsReconciled() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let request = try fixture.enqueue(id: "partial-settlement", createdAt: .now)
        let result = SudoResult(id: request.id, status: .completed, exitCode: 0)
        _ = try fixture.store.writeResultIfAbsent(result)
        let resultURL = fixture.paths.results.appendingPathComponent("\(request.id).json")
        let commitmentURL = fixture.paths.results.appendingPathComponent("\(request.id).commit")
        let resultData = try Data(contentsOf: resultURL)
        try Data(SHA256.hash(data: resultData)).write(to: commitmentURL, options: .atomic)

        try fixture.store.ensureDirectories()

        #expect(fixture.store.authoritativeResult(id: request.id)?.exitCode == 0)
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.paths.results.appendingPathComponent("\(request.id).commit").path
            )
        )
        #expect(fixture.store.state(id: request.id) == nil)
    }

    @Test("Spool startup commits a result archived before its marker")
    func archivedResultWithoutCommitmentIsReconciled() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let request = try fixture.enqueue(id: "archived-without-marker", createdAt: .now)
        _ = try fixture.store.writeResultIfAbsent(
            SudoResult(id: request.id, status: .completed, exitCode: 0)
        )
        try FileManager.default.removeItem(
            at: fixture.paths.requests.appendingPathComponent("\(request.id).json")
        )
        try FileManager.default.removeItem(
            at: fixture.paths.requests.appendingPathComponent("\(request.id).sh")
        )

        try fixture.store.ensureDirectories()

        #expect(fixture.store.authoritativeResult(id: request.id)?.exitCode == 0)
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

    @Test("Output collector retains marker-leading ordinary output in one bounded prefix")
    func markerLeadingOrdinaryOutputIsRetained() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let outputURL = fixture.paths.results.appendingPathComponent("underscore-output.txt")
        let outputDescriptor = Darwin.open(
            outputURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(0o600)
        )
        try #require(outputDescriptor >= 0)
        defer { Darwin.close(outputDescriptor) }
        var collector = SudoExecutionOutputCollector(
            outputDescriptor: outputDescriptor,
            readinessMarker: nil,
            controlMarkers: SudoExecutionControlMarkers()
        )
        let ordinaryOutput = Data(repeating: UInt8(ascii: "_"), count: 64 * 1_024)

        try collector.consume(ordinaryOutput)
        try collector.finish()

        #expect(try Data(contentsOf: outputURL) == ordinaryOutput)
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
        _ = try fixture.store.settle(
            SudoResult(id: id, status: .completed, exitCode: 0)
        )
        try Data().write(to: lockURL)
        let commitmentURL = fixture.paths.results.appendingPathComponent("\(id).commit")
        for url in [archiveURL, resultURL, commitmentURL, lockURL] {
            try FileManager.default.setAttributes(
                [.modificationDate: oldDate],
                ofItemAtPath: url.path
            )
        }

        try fixture.store.ensureDirectories()

        #expect(!FileManager.default.fileExists(atPath: archiveURL.path))
        #expect(!FileManager.default.fileExists(atPath: resultURL.path))
        #expect(!FileManager.default.fileExists(atPath: commitmentURL.path))
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
