import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

/// Lifecycle regression tests for ``SecretValueModel``.
///
/// The secret-backed model used the same long-lived settings observation shape
/// as the defaults and JSON models. This proves deallocation cancels the
/// parked observation task instead of leaving its stream alive.
@MainActor
@Suite struct SecretValueModelLifecycleTests {
    /// Box whose flag the stream's `onTermination` flips on the main actor.
    @MainActor
    private final class TerminationFlag {
        var didTerminate = false
    }

    @Test func droppingModelTearsDownObservation() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-5302-secret-value-model-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SecretFileStore(baseDirectory: tempDir)
        let key = SecretFileKey(id: "automation.socketPassword", fileName: "socket-control-password")
        let errorLog = SettingsErrorLog()

        let (stream, continuation) = AsyncStream<String>.makeStream()
        let flag = TerminationFlag()
        continuation.onTermination = { _ in
            Task { @MainActor in flag.didTerminate = true }
        }

        var model: SecretValueModel? = SecretValueModel(
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
            .appendingPathComponent("secret-value-model-lazy-observation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SecretFileStore(baseDirectory: tempDir)
        let key = SecretFileKey(id: "automation.socketPassword", fileName: "socket-control-password")
        let errorLog = SettingsErrorLog()
        let (stream, _) = AsyncStream<String>.makeStream()
        var streamCreations = 0

        _ = SecretValueModel(
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
