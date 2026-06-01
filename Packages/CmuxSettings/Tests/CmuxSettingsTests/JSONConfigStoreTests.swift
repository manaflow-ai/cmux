import Foundation
import Testing
@testable import CmuxSettings

@Suite("JSONConfigStore")
struct JSONConfigStoreTests {
    private func makeStore() -> (JSONConfigStore, URL, SettingCatalog) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-settings-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("cmux.json", isDirectory: false)
        return (JSONConfigStore(fileURL: fileURL), fileURL, SettingCatalog())
    }

    @Test func readsDefaultWhenFileMissing() async {
        let (store, _, _) = makeStore()
        let value = await store.value(for: JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        #expect(value == "")
    }

    @Test func roundTripsNestedKey() async throws {
        let (store, fileURL, _) = makeStore()
        try await store.set("hunter2", for: JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        let value = await store.value(for: JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        #expect(value == "hunter2")

        let data = try Data(contentsOf: fileURL)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let automation = parsed?["automation"] as? [String: Any]
        #expect(automation?["socketPassword"] as? String == "hunter2")
    }

    @Test func resetRemovesEntryAndPrunesEmptyParents() async throws {
        let (store, fileURL, _) = makeStore()
        try await store.set("hunter2", for: JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        try await store.reset(JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        let value = await store.value(for: JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        #expect(value == "")
        let data = try Data(contentsOf: fileURL)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["automation"] == nil)
    }

    @Test func toleratesJSONCComments() async throws {
        let (store, fileURL, _) = makeStore()
        let json = """
        {
          // commented
          "automation": {
            "socketPassword": "test",
          }
        }
        """
        try Data(json.utf8).write(to: fileURL)
        let value = await store.value(for: JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        #expect(value == "test")
    }

    @Test func observesExternalEdit() async throws {
        let (store, fileURL, _) = makeStore()
        try Data("{}".utf8).write(to: fileURL)

        let observed = Task<[String], Never> {
            var collected: [String] = []
            for await value in store.values(for: JSONKey<String>(id: "automation.socketPassword", defaultValue: "")) {
                collected.append(value)
                if collected.count == 2 { break }
            }
            return collected
        }

        // Give the subscriber Task time to register before the file change;
        // DispatchSource also coalesces events, so wait for delivery to settle.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let payload = #"{"automation":{"socketPassword":"injected"}}"#
        try Data(payload.utf8).write(to: fileURL)

        let collected = await withTimeout(seconds: 3) { await observed.value }
        #expect(collected.first == "")
        #expect(collected.last == "injected")
    }
}

private func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        for await result in group {
            if let result {
                group.cancelAll()
                return result
            }
        }
        fatalError("timed out without producing a value")
    }
}
