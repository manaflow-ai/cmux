import Foundation
import Testing

import CmuxRemoteWorkspace
@testable import CmuxWorkspaces

@MainActor
@Suite("CmuxSSHURLLaunchService")
struct CmuxSSHURLLaunchServiceTests {
    /// Recording drainer standing in for the app's `ProcessOutputCollector`.
    private final class RecordingDrainer: DiffViewerProcessOutputDraining, @unchecked Sendable {
        private let lock = NSLock()
        private var _started = false
        private var _finished = false
        private var _cancelled = false

        var started: Bool { lock.withLock { _started } }
        var finished: Bool { lock.withLock { _finished } }
        var cancelled: Bool { lock.withLock { _cancelled } }

        func start() { lock.withLock { _started = true } }

        @discardableResult
        func finish() -> String {
            lock.withLock { _finished = true }
            return ""
        }

        func cancel() { lock.withLock { _cancelled = true } }
    }

    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _failures: [CmuxSSHURLLaunchFailure] = []
        var failures: [CmuxSSHURLLaunchFailure] { lock.withLock { _failures } }
        func record(_ failure: CmuxSSHURLLaunchFailure) {
            lock.withLock { _failures.append(failure) }
        }
    }

    private func makeRequest() -> CmuxSSHURLRequest {
        let url = URL(string: "cmux://ssh?host=example.com")!
        switch CmuxSSHURLRequest.parse(url, supportedSchemes: CmuxSSHURLRequest.supportedSchemes) {
        case .success(.some(let request)):
            return request
        default:
            fatalError("fixture URL must parse to a request")
        }
    }

    private func makeService(
        drainer: @escaping @Sendable () -> RecordingDrainer,
        debugLog: @escaping @Sendable (String) -> Void = { _ in }
    ) -> CmuxSSHURLLaunchService {
        CmuxSSHURLLaunchService(
            makeOutputDrainer: { _, _ in drainer() },
            environment: { ["PATH": "/usr/bin:/bin", "CMUX_SOCKET": "stale"] },
            debugLog: debugLog
        )
    }

    @Test("A launchable CLI starts the drainer and reports success")
    func successfulLaunchStartsDrainer() async throws {
        let drainer = RecordingDrainer()
        let failures = FailureBox()
        let service = makeService(drainer: { drainer })

        let didLaunch = service.start(
            request: makeRequest(),
            cliURL: URL(fileURLWithPath: "/usr/bin/true"),
            socketPath: "/tmp/ssh-url-test.sock",
            onFailure: { failures.record($0) }
        )

        #expect(didLaunch)
        #expect(drainer.started)
        #expect(!drainer.cancelled)
    }

    @Test("A nil CLI reports a missing-CLI failure and never starts a drainer")
    func nilCLIReportsMissingCLI() async throws {
        let drainer = RecordingDrainer()
        let failures = FailureBox()
        let service = makeService(drainer: { drainer })

        let didLaunch = service.start(
            request: makeRequest(),
            cliURL: nil,
            socketPath: "/tmp/ssh-url-test.sock",
            onFailure: { failures.record($0) }
        )

        #expect(!didLaunch)
        #expect(!drainer.started)
        #expect(failures.failures == [.missingCLI])
    }

    @Test("A non-executable CLI reports a missing-CLI failure")
    func nonExecutableCLIReportsMissingCLI() async throws {
        let drainer = RecordingDrainer()
        let failures = FailureBox()
        let service = makeService(drainer: { drainer })

        let didLaunch = service.start(
            request: makeRequest(),
            cliURL: URL(fileURLWithPath: "/nonexistent/cmux-binary-\(UUID().uuidString)"),
            socketPath: "/tmp/ssh-url-test.sock",
            onFailure: { failures.record($0) }
        )

        #expect(!didLaunch)
        #expect(failures.failures == [.missingCLI])
    }

    @Test("terminateAll suppresses the nonzero-exit failure dialog")
    func terminateAllSuppressesFailureDialog() async throws {
        let drainer = RecordingDrainer()
        let failures = FailureBox()
        let service = makeService(drainer: { drainer })

        // `false` exits nonzero; without shutdown this would dispatch a failure.
        let didLaunch = service.start(
            request: makeRequest(),
            cliURL: URL(fileURLWithPath: "/usr/bin/false"),
            socketPath: "/tmp/ssh-url-test.sock",
            onFailure: { failures.record($0) }
        )
        #expect(didLaunch)

        service.terminateAll()
        // Give the termination handler's main-actor hop a chance to run.
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(failures.failures.isEmpty)
    }
}
