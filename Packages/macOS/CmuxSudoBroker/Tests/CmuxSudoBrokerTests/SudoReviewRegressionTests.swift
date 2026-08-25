@testable import CmuxSudoBroker
import Darwin
import Foundation
import Testing

@Suite("Sudo broker review regressions")
struct SudoReviewRegressionTests {
    @Test("Oversized request metadata is rejected before enqueue")
    func oversizedRequestMetadataDoesNotDisappear() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let id = "oversized-metadata"
        let request = SudoRequest(
            id: id,
            reason: String(repeating: "r", count: 70_000),
            requesterIdentity: SudoTestFixture.defaultRequesterIdentity,
            requesterCommand: "test-agent",
            currentDirectory: "/tmp",
            createdAt: .now
        )

        #expect(throws: (any Error).self) {
            try fixture.store.enqueue(
                SudoPendingRequest(request: request, script: "echo test\n")
            )
        }
        #expect(fixture.store.pendingRequests().isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.paths.requests.appendingPathComponent("\(id).sh").path
            )
        )
    }

    @Test("Interrupted request scripts do not consume admission capacity")
    func orphanedRequestScriptDoesNotConsumeCapacity() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let orphanURL = fixture.paths.requests.appendingPathComponent("orphan-request.sh")
        try Data("echo orphan\n".utf8).write(to: orphanURL)

        for index in 0..<7 {
            _ = try fixture.enqueue(id: "valid-request-\(index)", createdAt: .now)
        }

        #expect(throws: Never.self) {
            _ = try fixture.enqueue(id: "valid-request-final", createdAt: .now)
        }
    }

    @Test("A script cannot forge a privileged control marker")
    func ordinaryOutputContainingControlMarkerIsPreserved() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let outputURL = fixture.paths.results.appendingPathComponent("marker-collision.out")
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
        let forgedMarker = SudoExecutionControlMarkers().executionTimedOut
        try collector.consume(Data("before".utf8) + forgedMarker + Data("after".utf8))
        try collector.finish()

        #expect(collector.privilegedFailure == nil)
        #expect(try Data(contentsOf: outputURL) == Data("before".utf8) + forgedMarker + Data("after".utf8))
    }

    @Test("Approved runner admission is bounded")
    func approvedRunnerAdmissionIsBounded() async throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let launcher = TestRunnerLauncher()
        let resourcePolicy = SudoResourcePolicy(
            maximumPendingRequestCount: 16,
            maximumPendingScriptBytes: 16 * 1_024 * 1_024
        )
        let admissionStore = SudoSpoolStore(
            paths: fixture.paths,
            resourcePolicy: resourcePolicy
        )
        try admissionStore.ensureDirectories()
        let broker = SudoBroker(
            paths: fixture.paths,
            dependencies: SudoBrokerDependencies(
                clock: TestSudoClock(date: .now),
                pam: TestPAMChecker(enabled: true),
                runner: launcher,
                recovery: TestExecutionRecovery(),
                watcher: nil,
                requesterInspector: TestSudoProcessInspector()
            ),
            messages: .testMessages,
            resourcePolicy: resourcePolicy
        )
        _ = try await broker.start()
        for index in 0..<10 {
            let id = "active-runner-\(index)"
            let request = SudoRequest(
                id: id,
                reason: "regression test",
                requesterIdentity: SudoTestFixture.defaultRequesterIdentity,
                requesterCommand: "test-agent",
                currentDirectory: "/tmp",
                createdAt: .now
            )
            try admissionStore.enqueue(
                SudoPendingRequest(request: request, script: "echo test\n")
            )
            _ = try await broker.refresh()
            await broker.approve(id: id)
        }

        #expect((await launcher.launchedRequestIDs).count <= 8)
    }

    @Test("Orphan recovery recognizes tokenized sudo and helper commands")
    func orphanRecoveryRecognizesTokenizedArguments() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let approvedScriptURL = fixture.paths.approved.appendingPathComponent("tokenized.sh")
        let identity = SudoTestFixture.defaultRequesterIdentity
        let token = SudoExecutionControlMarkers().token
        let prompt = SudoAuthenticationOutputDetector.passwordPrompt
        let sudoArguments = [
            "/usr/bin/sudo", "-k", "-S", "-p", prompt,
            "/Applications/cmux.app/Contents/MacOS/cmux",
            SudoPrivilegedExecutor.hiddenCommand, "12", "1234", approvedScriptURL.path, token,
        ]
        let sudoInspector = SequencedSudoProcessInspector(
            processIdentifier: identity.processIdentifier,
            identities: [identity, identity],
            arguments: sudoArguments
        )
        let sudoInventory = SudoOrphanProcessInventory(inspector: sudoInspector)
            .identitiesByScriptPath(approvedScriptURLs: [approvedScriptURL])
        #expect(sudoInventory[approvedScriptURL.standardizedFileURL.path] == [identity])

        let helperArguments = [
            "/Applications/cmux.app/Contents/MacOS/cmux",
            SudoPrivilegedExecutor.hiddenCommand, "12", "1234", approvedScriptURL.path, token,
        ]
        let helperInspector = SequencedSudoProcessInspector(
            processIdentifier: identity.processIdentifier,
            identities: [identity, identity],
            arguments: helperArguments
        )
        let helperInventory = SudoOrphanProcessInventory(inspector: helperInspector)
            .identitiesByScriptPath(approvedScriptURLs: [approvedScriptURL])
        #expect(helperInventory[approvedScriptURL.standardizedFileURL.path] == [identity])
    }

    @Test("Approval reuses complete artifacts left before state persistence")
    func approvalTransitionReconcilesCrashLeftArtifacts() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date.now
        let request = try fixture.enqueue(id: "approval-recovery", createdAt: now)
        let pending = try #require(
            fixture.store.pendingRequests().first { $0.request.id == request.id }
        )
        let manifest = SudoExecutionManifest(
            id: request.id,
            requesterIdentity: SudoTestFixture.defaultRequesterIdentity,
            currentDirectory: request.currentDirectory,
            deadline: request.approvalDeadline.addingTimeInterval(SudoBroker.executionGraceSeconds)
        )
        try Data(pending.script.utf8).write(to: fixture.store.approvedScriptURL(id: request.id))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: fixture.paths.executions
            .appendingPathComponent("\(request.id).json"))

        let transition = try fixture.store.transitionToApproved(
            pending: pending,
            now: now,
            executionGraceSeconds: SudoBroker.executionGraceSeconds
        )
        guard case .approved(let recoveredManifest) = transition else {
            Issue.record("approval did not reconcile the existing artifacts")
            return
        }
        #expect(recoveredManifest == manifest)
        #expect(fixture.store.state(id: request.id)?.phase == .approved)
    }

    @Test("Crash-left atomic-write temporary files are pruned")
    func atomicWriteTemporaryFilesAreReclaimed() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let temporaryURL = fixture.paths.requests
            .appendingPathComponent(".request.json.tmp.123.\(UUID().uuidString)")
        try Data("orphaned temporary data".utf8).write(to: temporaryURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-48 * 60 * 60)],
            ofItemAtPath: temporaryURL.path
        )

        try fixture.store.ensureDirectories()

        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    }
}
