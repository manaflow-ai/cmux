import Foundation
import Testing
@testable import CmuxSettings

/// Behavior of the `customSidebars.renderer` setting through the real JSON
/// store: the on-disk strings users put in `~/.config/cmux/cmux.json` must
/// decode to the right renderer, and anything else must fall back to the
/// default (native in-process rendering).
@Suite("customSidebars.renderer")
struct CustomSidebarRendererSettingTests {
    private func makeStore() -> (JSONConfigStore, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-renderer-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("cmux.json", isDirectory: false)
        return (JSONConfigStore(fileURL: fileURL), fileURL)
    }

    @Test func defaultsToInProcessWhenUnset() async {
        let (store, _) = makeStore()
        let value = await store.value(for: SettingCatalog().customSidebars.renderer)
        #expect(value == .inProcess)
    }

    @Test func readsRemoteFromHandEditedConfigFile() async throws {
        let (store, fileURL) = makeStore()
        try #"{ "customSidebars": { "renderer": "remote" } }"#
            .write(to: fileURL, atomically: true, encoding: .utf8)
        let value = await store.value(for: SettingCatalog().customSidebars.renderer)
        #expect(value == .remote)
    }

    @Test func unknownRawValueFallsBackToTheDefault() async throws {
        let (store, fileURL) = makeStore()
        try #"{ "customSidebars": { "renderer": "yolo" } }"#
            .write(to: fileURL, atomically: true, encoding: .utf8)
        let value = await store.value(for: SettingCatalog().customSidebars.renderer)
        #expect(value == .inProcess)
    }

    @Test func roundTripsThroughTheStore() async throws {
        let (store, fileURL) = makeStore()
        try await store.set(.remote, for: SettingCatalog().customSidebars.renderer)
        let value = await store.value(for: SettingCatalog().customSidebars.renderer)
        #expect(value == .remote)

        // The on-disk representation is the raw string, hand-editable.
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        let section = parsed?["customSidebars"] as? [String: Any]
        #expect(section?["renderer"] as? String == "remote")
    }
}
