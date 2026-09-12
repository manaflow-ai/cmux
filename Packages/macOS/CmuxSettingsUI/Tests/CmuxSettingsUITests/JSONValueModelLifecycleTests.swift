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

    @Test func queuedUpdatesSurviveModelTeardown() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("json-value-model-write-queue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = JSONConfigStore(fileURL: tempDir.appendingPathComponent("cmux.json"))
        let key = JSONKey<ChromeTokenOverrides>(id: "chrome.overrides", defaultValue: .empty)
        let errorLog = SettingsErrorLog()
        let accent = try #require(ChromeColor(hex: "#123456"))
        let surface = try #require(ChromeColor(hex: "#ABCDEF"))

        var model: JSONValueModel<ChromeTokenOverrides>? = JSONValueModel(
            store: store,
            key: key,
            errorLog: errorLog
        )
        let firstWrite = model!.update { current in
            var values = current.values
            values[.accent] = accent
            return ChromeTokenOverrides(values)
        }
        let secondWrite = model!.update { current in
            var values = current.values
            values[.surface] = surface
            return ChromeTokenOverrides(values)
        }

        model = nil
        await firstWrite.value
        await secondWrite.value

        let persisted = await store.value(for: key)
        #expect(persisted[.accent] == accent)
        #expect(persisted[.surface] == surface)
    }

    @Test func queuedWriteFailureIsLoggedAfterModelTeardown() async {
        let blockedParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("json-value-model-write-error-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: blockedParent) }
        try? Data().write(to: blockedParent)

        let store = JSONConfigStore(fileURL: blockedParent.appendingPathComponent("cmux.json"))
        let key = JSONKey<String>(id: "automation.socketPassword", defaultValue: "")
        let errorLog = SettingsErrorLog()
        var model: JSONValueModel<String>? = JSONValueModel(
            store: store,
            key: key,
            errorLog: errorLog
        )

        let write = model!.set("persisted")
        model = nil
        await write.value

        #expect(errorLog.entries.count == 1)
        #expect(errorLog.entries.first?.keyID == key.id)
    }
}
