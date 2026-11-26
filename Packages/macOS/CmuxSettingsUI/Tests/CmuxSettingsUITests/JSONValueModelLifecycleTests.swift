import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

/// Lifecycle regression tests for ``JSONValueModel``.
///
/// These mirror the `DefaultsValueModel` leak repro against the JSON-backed
/// settings model: once the observation task is parked awaiting the next
/// element, dropping the model must cancel the task and terminate the stream.
@MainActor
@Suite struct JSONValueModelLifecycleTests {
    /// Box whose flag the stream's `onTermination` flips on the main actor.
    @MainActor
    private final class TerminationFlag {
        var didTerminate = false
    }

    @Test func droppingModelTearsDownObservation() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-5302-json-value-model-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = JSONConfigStore(fileURL: tempDir.appendingPathComponent("cmux.json"))
        let key = JSONKey<String>(id: "automation.socketPassword", defaultValue: "")
        let errorLog = SettingsErrorLog()

        let (stream, continuation) = AsyncStream<String>.makeStream()
        let flag = TerminationFlag()
        continuation.onTermination = { _ in
            Task { @MainActor in flag.didTerminate = true }
        }

        var model: JSONValueModel<String>? = JSONValueModel(
            store: store,
            key: key,
            errorLog: errorLog,
            makeStream: { stream }
        )
        model?.startObserving()

        continuation.yield("observed")
        var settleSpins = 0
        while model?.current != "observed", settleSpins < 100_000 {
            await Task.yield()
            settleSpins += 1
        }
        #expect(model?.current == "observed")

        model = nil

        var spins = 0
        while !flag.didTerminate, spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(flag.didTerminate)
    }

    @Test func initializationDoesNotStartObservationStream() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("json-value-model-lazy-observation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = JSONConfigStore(fileURL: tempDir.appendingPathComponent("cmux.json"))
        let key = JSONKey<String>(id: "automation.socketPassword", defaultValue: "")
        let errorLog = SettingsErrorLog()
        let (stream, _) = AsyncStream<String>.makeStream()
        var streamCreations = 0

        _ = JSONValueModel(
            store: store,
            key: key,
            errorLog: errorLog,
            makeStream: {
                streamCreations += 1
                return stream
            }
        )

        #expect(streamCreations == 0)
    }
}
