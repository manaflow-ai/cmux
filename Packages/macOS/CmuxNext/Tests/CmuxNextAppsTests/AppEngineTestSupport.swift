import Foundation
import Observation
import Synchronization
@testable import CmuxNextApps

/// A clock whose sleeps end only when the test advances it.
nonisolated final class ManualAppClock: AppEngineClock, Sendable {
    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let state = Mutex<(now: Duration, next: Int, sleepers: [Int: Sleeper])>((.zero, 0, [:]))

    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func delay(for duration: Duration) async throws {
        let id = state.withLock { state in
            state.next += 1
            return state.next
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = state.withLock { state -> Bool in
                    if Task.isCancelled { return true }
                    state.sleepers[id] = Sleeper(deadline: state.now + duration, continuation: continuation)
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now += duration
            let ready = state.sleepers.filter { $0.value.deadline <= state.now }
            for key in ready.keys { state.sleepers.removeValue(forKey: key) }
            return Array(ready.values)
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

/// A sink that records requests and answers from a table.
nonisolated final class RecordingSink: AppOperationSink, Sendable {
    private let state = Mutex<[AppOperationRequest]>([])
    let answers: @Sendable (AppOperationRequest) -> Result<AppOperationResult, AppOperationError>

    init(answers: @escaping @Sendable (AppOperationRequest) -> Result<AppOperationResult, AppOperationError> = { .failure(.unsupported($0.op)) }) {
        self.answers = answers
    }

    var requests: [AppOperationRequest] { state.withLock { $0 } }

    func perform(_ request: AppOperationRequest) async -> Result<AppOperationResult, AppOperationError> {
        state.withLock { $0.append(request) }
        return answers(request)
    }
}

/// Collects engine output and applies scene batches per mount.
nonisolated final class OutputCollector: Sendable {
    private let state = Mutex<(outputs: [AppEngineOutput], scenes: [String: AppScene])>(([], [:]))

    var sink: @Sendable (AppEngineOutput) -> Void {
        { [self] output in
            state.withLock { state in
                state.outputs.append(output)
                if case let .scene(mount, ops) = output { state.scenes[mount, default: AppScene()].apply(ops) }
            }
        }
    }

    var outputs: [AppEngineOutput] { state.withLock { $0.outputs } }
    func scene(_ mount: String) -> AppScene { state.withLock { $0.scenes[mount] ?? AppScene() } }
    var logs: [String] { outputs.compactMap { if case let .log(_, message) = $0 { message } else { nil } } }
}

/// Waits (bounded) until `condition` holds.
nonisolated func eventually(_ timeout: Duration = .seconds(30), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Waits until `condition` holds over main-actor observable state (`AppHost`,
/// `AppSceneModel`). It is re-checked only when a property it read changes, so
/// a loaded runner makes the wait later, never false; the test's time limit
/// bounds an event that never comes. Returns whether it holds.
@MainActor func observed(_ condition: @MainActor () -> Bool) async -> Bool {
    while !Task.isCancelled {
        let (changed, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let holds = withObservationTracking(condition) {
            signal.yield()
            signal.finish()
        }
        if holds { return true }
        for await _ in changed { break }
    }
    return condition()
}

nonisolated enum TestApps {
    /// A temporary bundle with a manifest and an IIFE `main`.
    static func bundle(id: String = "local/test", scopes: [String: String] = [:], main body: String) throws -> (AppManifest, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-apps-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appending(path: "dist"), withIntermediateDirectories: true)
        let manifest: AppJSON = [
            "manifestVersion": 1, "id": .string(id), "name": "Test", "version": "1.0.0", "description": "t",
            "engines": ["cmux": "^1.0"], "main": "dist/main.js", "scopes": .object(scopes.mapValues(AppJSON.string)),
        ]
        try Data(manifest.jsonText.utf8).write(to: directory.appending(path: "cmux-app.json"))
        try Data("var __cmuxAppExports = (() => { \(body) })();".utf8).write(to: directory.appending(path: "dist/main.js"))
        return (try AppManifest.decode(manifest), directory)
    }

    static func sample(_ name: String) throws -> (AppManifest, URL) {
        let directory = AppPlatformResources.samples.appending(path: name)
        return (try AppManifest.decode(Data(contentsOf: directory.appending(path: "cmux-app.json"))), directory)
    }
}
