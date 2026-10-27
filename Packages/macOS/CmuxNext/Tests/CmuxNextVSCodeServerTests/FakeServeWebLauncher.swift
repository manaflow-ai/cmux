import CmuxNextCompat
import CmuxNextVSCodeServer
import Foundation

/// A `serve-web` stand-in: each start records its launch and answers on the next port, or fails
/// with `failure`. With `holdsStart` a start waits until ``releaseStart()``.
actor FakeServeWebLauncher: VSCodeServeWebLaunching {
    private(set) var launches: [VSCodeServeWebLaunch] = []
    private(set) var processes: [FakeServeWebProcess] = []
    private let failure: VSCodeServeWebError?
    private let holdsStart: Bool
    private var started: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var didStart = false

    init(failure: VSCodeServeWebError? = nil, holdsStart: Bool = false) {
        self.failure = failure
        self.holdsStart = holdsStart
    }

    func start(_ launch: VSCodeServeWebLaunch) async throws -> VSCodeServeWebStarted {
        launches.append(launch)
        if let failure { throw failure }
        let process = FakeServeWebProcess()
        processes.append(process)
        if holdsStart {
            didStart = true
            started?.resume()
            started = nil
            await withCheckedContinuation { release = $0 }
        }
        let token = launch.arguments.last.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        return VSCodeServeWebStarted(handle: process, url: URL(string: "http://127.0.0.1:\(50000 + processes.count)/?tkn=\(token)")!)
    }

    /// Returns once a held start has begun.
    func waitForStart() async {
        if didStart { return }
        await withCheckedContinuation { started = $0 }
    }

    /// Lets a held start answer.
    func releaseStart() {
        release?.resume()
        release = nil
    }
}

/// A fake server process: running until terminated.
final class FakeServeWebProcess: VSCodeServeWebProcessHandle {
    // A test-only flag flipped by `terminate()` from any task; read synchronously by the test.
    private let running = Atomic(true)

    var isRunning: Bool { running.load(ordering: .acquiring) }

    func terminate() { running.store(false, ordering: .releasing) }
}
