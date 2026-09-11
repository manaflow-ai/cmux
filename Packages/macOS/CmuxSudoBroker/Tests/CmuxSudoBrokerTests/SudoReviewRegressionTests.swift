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
            requesterIdentity: pending.request.requesterIdentity!,
            currentDirectory: pending.request.currentDirectory,
            directoryIdentity: try SudoDirectoryIdentity(path: pending.request.currentDirectory),
            deadline: pending.request.approvalDeadline.addingTimeInterval(
                SudoBroker.executionGraceSeconds
            )
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

    @Test("Recovered runners are reconciled at their durable deadline")
    func recoveredRunnerLivenessIsBounded() async throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let request = try fixture.enqueue(id: "recovered-runner", createdAt: now)
        let pending = try #require(
            fixture.store.pendingRequests().first { $0.request.id == request.id }
        )
        let transition = try fixture.store.transitionToApproved(
            pending: pending,
            now: now,
            executionGraceSeconds: SudoBroker.executionGraceSeconds
        )
        guard case .approved(let manifest) = transition else {
            Issue.record("recovery fixture did not enter approved state")
            return
        }
        try fixture.store.writeState(
            SudoRequestState(
                id: request.id,
                phase: .executing,
                updatedAt: now,
                runner: SudoProcessIdentity(
                    processIdentifier: 5_200,
                    startSeconds: 200,
                    startMicroseconds: 1
                )
            )
        )
        let clock = TestSudoClock(date: now)
        let recovery = ReviewRecovery(
            dispositions: [.runnerActive, .recovered]
        )
        let broker = SudoBroker(
            paths: fixture.paths,
            dependencies: SudoBrokerDependencies(
                clock: clock,
                pam: TestPAMChecker(enabled: true),
                runner: TestRunnerLauncher(),
                recovery: recovery,
                watcher: nil,
                requesterInspector: TestSudoProcessInspector()
            ),
            messages: .testMessages
        )

        _ = try await broker.start()
        #expect(await recovery.callCount == 1)
        for _ in 0..<20 { await Task.yield() }
        await clock.advance(to: manifest.deadline)
        for _ in 0..<1_000 {
            await Task.yield()
            if await recovery.callCount >= 2,
               fixture.store.result(id: request.id) != nil {
                break
            }
        }

        #expect(await recovery.callCount >= 2)
        #expect(fixture.store.result(id: request.id)?.errorCode == .executionInterrupted)
    }

    @Test("Cleanup recovery is not retried for every unrelated refresh")
    func cleanupRecoveryHasBackoff() async throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let request = try fixture.enqueue(id: "cleanup-backoff", createdAt: now)
        let pending = try #require(
            fixture.store.pendingRequests().first { $0.request.id == request.id }
        )
        _ = try fixture.store.transitionToApproved(
            pending: pending,
            now: now,
            executionGraceSeconds: SudoBroker.executionGraceSeconds
        )
        let survivor = SudoProcessIdentity(
            processIdentifier: 5_201,
            startSeconds: 201,
            startMicroseconds: 1
        )
        try fixture.store.writeState(
            SudoRequestState(
                id: request.id,
                phase: .executing,
                updatedAt: now,
                execution: survivor,
                cleanupSurvivors: [survivor]
            )
        )
        _ = try fixture.store.settle(
            SudoResult(
                id: request.id,
                status: .failed,
                errorCode: .processCleanupFailed,
                note: "cleanup"
            )
        )
        let recovery = ReviewRecovery(dispositions: [.cleanupIncomplete, .cleanupIncomplete])
        let broker = SudoBroker(
            paths: fixture.paths,
            dependencies: SudoBrokerDependencies(
                clock: TestSudoClock(date: now),
                pam: TestPAMChecker(enabled: true),
                runner: TestRunnerLauncher(),
                recovery: recovery,
                watcher: nil,
                requesterInspector: TestSudoProcessInspector()
            ),
            messages: .testMessages
        )

        _ = try await broker.start()
        _ = try await broker.refresh()
        _ = try await broker.refresh()

        #expect(await recovery.callCount == 1)
    }

    @Test("Reviewed-byte transport has an independent deadline", .timeLimit(.minutes(1)))
    func reviewedByteTransportDeadlineIsBounded() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        var masterDescriptor: Int32 = -1
        var slaveDescriptor: Int32 = -1
        #expect(openpty(&masterDescriptor, &slaveDescriptor, nil, nil, nil) == 0)
        try #require(masterDescriptor >= 0 && slaveDescriptor >= 0)
        defer {
            Darwin.close(masterDescriptor)
            Darwin.close(slaveDescriptor)
        }
        let receiver = SudoPrivilegedScriptReceiver(
            inputDescriptor: slaveDescriptor,
            outputDescriptor: slaveDescriptor,
            temporaryDirectoryURL: fixture.root
        )

        #expect(throws: (any Error).self) {
            try receiver.withReceivedDescriptor(
                expectedByteCount: 1,
                deadline: Date.now.addingTimeInterval(0.05)
            ) { _ in }
        }
    }

    @Test("Approval retains the script snapshot shown before a refresh")
    func approvalUsesOriginalReviewedSnapshot() async throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let request = try fixture.enqueue(id: "snapshot-refresh", createdAt: now)
        let launcher = TestRunnerLauncher()
        let broker = SudoBroker(
            paths: fixture.paths,
            dependencies: SudoBrokerDependencies(
                clock: TestSudoClock(date: now),
                pam: TestPAMChecker(enabled: true),
                runner: launcher,
                recovery: TestExecutionRecovery(),
                watcher: nil,
                requesterInspector: TestSudoProcessInspector()
            ),
            messages: .testMessages
        )
        _ = try await broker.start()
        try Data("echo replaced\n".utf8).write(
            to: fixture.paths.requests.appendingPathComponent("\(request.id).sh")
        )
        _ = try await broker.refresh()
        await broker.approve(id: request.id)

        let reviewedScript = await launcher.reviewedScripts[request.id]
        if let reviewedScript {
            #expect(reviewedScript == Data("echo test\n".utf8))
        } else {
            #expect(fixture.store.result(id: request.id)?.errorCode == .stagingFailed)
        }
    }

    @Test("Unconsumed output is included in the bounded result budget")
    func unconsumedOutputRetentionIsBounded() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let policy = SudoResourcePolicy(maximumOutputBytes: 10)
        let store = SudoSpoolStore(paths: fixture.paths, resourcePolicy: policy)
        try store.ensureDirectories()
        let oldDate = Date.now.addingTimeInterval(-48 * 60 * 60)
        for index in 0..<3 {
            let url = fixture.paths.results.appendingPathComponent("output-\(index).out")
            try Data(repeating: UInt8(index), count: 8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: oldDate.addingTimeInterval(TimeInterval(index))],
                ofItemAtPath: url.path
            )
        }

        try store.ensureDirectories()

        let outputNames = try FileManager.default
            .contentsOfDirectory(atPath: fixture.paths.results.path)
            .filter { $0.hasSuffix(".out") }
        var remainingBytes = 0
        for name in outputNames {
            remainingBytes += (try FileManager.default.attributesOfItem(
                atPath: fixture.paths.results.appendingPathComponent(name).path
            )[.size] as? NSNumber)?.intValue ?? 0
        }
        #expect(remainingBytes <= policy.maximumOutputBytes)
    }
}

private actor ReviewRecovery: SudoInterruptedExecutionRecovering {
    private let dispositions: [SudoExecutionRecoveryDisposition]
    private var index = 0
    private(set) var callCount = 0

    init(dispositions: [SudoExecutionRecoveryDisposition]) {
        self.dispositions = dispositions
    }

    func recover(
        states: [SudoRequestState],
        approvedDirectory: URL
    ) async -> [String: SudoExecutionRecoveryDisposition] {
        callCount += 1
        let disposition = dispositions[min(index, dispositions.count - 1)]
        index += 1
        return Dictionary(uniqueKeysWithValues: states.map { ($0.id, disposition) })
    }
}
