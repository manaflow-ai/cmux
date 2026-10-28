@testable import CmuxNextSettings
import CmuxNextActions
import CmuxNextDesign
import Foundation
import Testing

@MainActor struct InspectorOrderRevisionTests {
    private func wire(_ time: Int, _ writer: String, _ section: String) -> JSONValue {
        .array([.string("@cmux-order/v1/\(time)/\(writer)"), .string(section)])
    }

    @Test(arguments: [false, true])
    func nativeWritesKeepNewestStampAcrossReload(_ reversed: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "inspector-order-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        let file = CmuxConfigFile(url: url)
        let older = wire(10, "a", "changes"), newer = wire(20, "b", "outputs")
        for value in reversed ? [newer, older] : [older, newer] { try await file.setInspectorOrder(value) }
        let reopened = CmuxConfigFile(url: url)
        #expect(try await reopened.value(at: InspectorOrderRevision.path) == newer)
        let document = try await reopened.document()
        let display = AgentPaneDisplaySetting(fileRoot: document)
        #expect(display.values[InspectorOrderRevision.path.joined(separator: ".")] == newer)
    }

    @Test func resetAllIsAStampedDefaultAndLateWritesCannotRestoreTheOldOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "inspector-reset-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(),
            fileURL: directory.appending(path: "cmux.json"),
            managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        let old = wire(20, "b", "outputs")
        try await settings.setSetting(at: InspectorOrderRevision.path, to: old, by: .caller("page"))
        try await settings.resetAllSettings(by: .user)
        let persisted = try await settings.file.value(at: InspectorOrderRevision.path)
        let reset = try #require(persisted)
        let stamp = try #require(InspectorOrderRevision.stamp(reset))
        #expect(stamp.time > 20)
        guard case .array(let values) = reset else { Issue.record("Reset must be a stamped list"); return }
        let descriptor = try #require(SettingsSchema.descriptor(for: InspectorOrderRevision.path))
        #expect(JSONValue.array(Array(values.dropFirst())) == descriptor.defaultValue)
        try await settings.setSetting(at: InspectorOrderRevision.path, to: old, by: .caller("page"))
        #expect(try await settings.file.value(at: InspectorOrderRevision.path) == reset)
    }

    @Test func equalTimestampUsesWriterAndLegacyWritesAcquireAStamp() throws {
        let a = wire(10, "a", "changes"), b = wire(10, "b", "outputs")
        #expect(InspectorOrderRevision.resolving(a, over: b, now: 1, writer: "host") == nil)
        #expect(InspectorOrderRevision.resolving(b, over: a, now: 1, writer: "host") == b)
        let upgraded = InspectorOrderRevision.resolving(.array([.string("changes")]), over: b, now: 1, writer: "host")
        #expect(upgraded == wire(11, "host", "changes"))
    }
}
