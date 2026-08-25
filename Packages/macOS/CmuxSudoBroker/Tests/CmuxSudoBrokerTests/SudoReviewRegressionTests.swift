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
}
