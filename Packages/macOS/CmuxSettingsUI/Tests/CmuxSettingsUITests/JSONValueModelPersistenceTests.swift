import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

/// Persistence tests for the awaitable, lifecycle-owned JSON model writes.
@MainActor
@Suite
struct JSONValueModelPersistenceTests {
    @Test func updateReturnsCompletionHandleAndPersistsValue() async {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let key = JSONKey<String>(id: "automation.socketPassword", defaultValue: "")
        let model = JSONValueModel(
            store: store,
            key: key,
            errorLog: SettingsErrorLog()
        )

        let write = model.update { _ in "persisted" }
        await write.value

        #expect(await store.value(for: key) == "persisted")
        #expect(model.lastWriteError == nil)
    }

    @Test func resetReturnsCompletionHandleAndRemovesValue() async throws {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let key = JSONKey<String>(id: "automation.socketPassword", defaultValue: "")
        try await store.set("persisted", for: key)
        let model = JSONValueModel(
            store: store,
            key: key,
            errorLog: SettingsErrorLog()
        )

        let reset = model.reset()
        await reset.value

        #expect(await store.value(for: key) == "")
        #expect(model.lastWriteError == nil)
    }

    private func makeStore() -> (JSONConfigStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("json-value-model-persistence-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("cmux.json")
        return (JSONConfigStore(fileURL: fileURL), fileURL)
    }
}
