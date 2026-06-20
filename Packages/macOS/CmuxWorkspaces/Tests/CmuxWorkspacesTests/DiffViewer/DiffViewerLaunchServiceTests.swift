import Foundation
import Testing

@testable import CmuxWorkspaces

@MainActor
@Suite("DiffViewerLaunchService")
struct DiffViewerLaunchServiceTests {
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

    private func makeService(
        drainer: @escaping @Sendable () -> RecordingDrainer,
        beep: @escaping @MainActor @Sendable () -> Void = {},
        debugLog: @escaping @Sendable (String) -> Void = { _ in }
    ) -> DiffViewerLaunchService {
        DiffViewerLaunchService(
            makeOutputDrainer: { _, _ in drainer() },
            environment: { ["PATH": "/usr/bin:/bin"] },
            beep: beep,
            debugLog: debugLog
        )
    }

    @Test("A launchable CLI starts the drainer and reports success")
    func successfulLaunchStartsDrainer() async throws {
        let drainer = RecordingDrainer()
        let service = makeService(drainer: { drainer })

        let didLaunch = service.launch(
            cliURL: URL(fileURLWithPath: "/usr/bin/true"),
            socketPath: "/tmp/diff-viewer-test.sock",
            cwd: NSTemporaryDirectory(),
            workspaceId: UUID(),
            surfaceId: UUID()
        )

        #expect(didLaunch)
        #expect(drainer.started)
        #expect(!drainer.cancelled)
    }

    @Test("A missing CLI cancels the drainer and reports failure without beeping")
    func failedLaunchCancelsDrainerAndDoesNotBeep() async throws {
        let drainer = RecordingDrainer()
        let beepBox = BeepBox()
        let service = makeService(
            drainer: { drainer },
            beep: { beepBox.fire() }
        )

        let didLaunch = service.launch(
            cliURL: URL(fileURLWithPath: "/nonexistent/cmux-binary-\(UUID().uuidString)"),
            socketPath: "/tmp/diff-viewer-test.sock",
            cwd: NSTemporaryDirectory(),
            workspaceId: UUID(),
            surfaceId: nil
        )

        #expect(!didLaunch)
        #expect(drainer.started)
        #expect(drainer.cancelled)
        #expect(!drainer.finished)
        // A launch that throws never spawns a child, so the nonzero-exit beep
        // cue must not fire.
        #expect(!beepBox.fired)
    }

    private final class BeepBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _fired = false
        var fired: Bool { lock.withLock { _fired } }
        func fire() { lock.withLock { _fired = true } }
    }
}
