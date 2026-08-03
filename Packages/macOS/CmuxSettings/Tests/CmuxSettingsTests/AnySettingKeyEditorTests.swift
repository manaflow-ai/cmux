import Foundation
import Testing

@testable import CmuxSettings

@Suite("AnySettingKey native editor", .serialized)
struct AnySettingKeyEditorTests {
    @Test func userDefaultsEnumRoundTripsAndResetsThroughTypedKey() async throws {
        let suite = "cmux.editor-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let defaultsStore = UserDefaultsSettingsStore(defaults: defaults)
        let stores = makeFileStores()
        defer { try? FileManager.default.removeItem(at: stores.directory) }
        let key = SettingCatalog().app.appearance
        let erased = AnySettingKey(key)

        #expect(erased.editorDefaultValue == .text("system"))
        try await erased.writeEditorValue(.text("dark"), defaultsStore, stores.json, stores.secret)
        #expect(await defaultsStore.value(for: key) == .dark)
        #expect(try await erased.readEditorValue(defaultsStore, stores.json, stores.secret) == .text("dark"))

        try await erased.resetEditorValue(defaultsStore, stores.json, stores.secret)
        #expect(await defaultsStore.value(for: key) == .system)
    }

    @Test func jsonObjectRoundTripsAndResetsThroughTypedKey() async throws {
        let suite = "cmux.editor-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let defaultsStore = UserDefaultsSettingsStore(defaults: defaults)
        let stores = makeFileStores()
        defer { try? FileManager.default.removeItem(at: stores.directory) }
        let key = JSONKey<[String: Int]>(id: "native.editor.object", defaultValue: [:])
        let erased = AnySettingKey(key)
        let value = SettingValue.object(["one": .integer(1), "two": .integer(2)])

        try await erased.writeEditorValue(value, defaultsStore, stores.json, stores.secret)
        #expect(await stores.json.value(for: key) == ["one": 1, "two": 2])
        #expect(try await erased.readEditorValue(defaultsStore, stores.json, stores.secret) == value)

        try await erased.resetEditorValue(defaultsStore, stores.json, stores.secret)
        #expect(await stores.json.value(for: key) == [:])
    }

    @Test func secretRoundTripsAndRejectsWrongShape() async throws {
        let suite = "cmux.editor-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let defaultsStore = UserDefaultsSettingsStore(defaults: defaults)
        let stores = makeFileStores()
        defer { try? FileManager.default.removeItem(at: stores.directory) }
        let key = SecretFileKey(id: "native.editor.secret", fileName: "native-editor-secret")
        let erased = AnySettingKey(key)

        try await erased.writeEditorValue(.text("token"), defaultsStore, stores.json, stores.secret)
        #expect(try await stores.secret.value(for: key) == "token")
        #expect(try await erased.readEditorValue(defaultsStore, stores.json, stores.secret) == .text("token"))

        await #expect(throws: SettingValueError.unsupportedValue(key.id)) {
            try await erased.writeEditorValue(.boolean(true), defaultsStore, stores.json, stores.secret)
        }
    }

    @Test func editableTextPreservesShapeAndValidatesInput() throws {
        #expect(try SettingValue.boolean(false).replacingValue(with: "yes") == .boolean(true))
        #expect(try SettingValue.integer(0).replacingValue(with: "42") == .integer(42))
        #expect(try SettingValue.number(0).replacingValue(with: "2.5") == .number(2.5))
        #expect(try SettingValue.text("").replacingValue(with: "value") == .text("value"))
        #expect(
            try SettingValue.object([:]).replacingValue(with: #"{"enabled":true}"#)
                == .object(["enabled": .boolean(true)])
        )
        #expect(throws: SettingValueError.invalidBoolean("maybe")) {
            try SettingValue.boolean(false).replacingValue(with: "maybe")
        }
        #expect(throws: SettingValueError.invalidJSON) {
            try SettingValue.array([]).replacingValue(with: #"{"wrong":"shape"}"#)
        }
    }

    private func makeFileStores() -> (
        directory: URL,
        json: JSONConfigStore,
        secret: SecretFileStore
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-native-editor-\(UUID().uuidString)", isDirectory: true)
        return (
            directory,
            JSONConfigStore(fileURL: directory.appendingPathComponent("cmux.json")),
            SecretFileStore(baseDirectory: directory)
        )
    }
}
