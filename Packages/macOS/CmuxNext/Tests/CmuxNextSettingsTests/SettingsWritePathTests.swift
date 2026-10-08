import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// One write path: the typed setters the palette and onboarding call are
/// thin wrappers over `setSetting`, so each write is validated against the
/// schema (and counted in `validatedWrites`) exactly like a Settings window
/// edit, and a value the schema refuses never reaches the file.
@MainActor @Suite struct SettingsWritePathTests {
    func make() throws -> (SettingsController, URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-write-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url)
        return (settings, url, directory)
    }

    func document(_ url: URL) throws -> JSONValue { try JSONC.parse(String(contentsOf: url, encoding: .utf8)) }

    /// Each typed setter, the schema key it writes and the value it leaves.
    static let setters: [(key: String, value: JSONValue?, write: @MainActor (SettingsController) async throws -> Void)] = [
        ("appearance.density", "comfortable", { try await $0.setDensity(.comfortable) }),
        ("ui.animationSpeed", "off", { try await $0.setAnimationSpeed(.off) }),
        ("window.titlebar", "standard", { try await $0.setTitlebar(.standard) }),
        ("browser.defaultEngine", "webkit", { try await $0.setBrowserDefaultEngine(.webkit) }),
        ("browser.showBookmarksBar", true, { try await $0.setShowBookmarksBar(true) }),
        ("browser.hibernation", "aggressive", { try await $0.setBrowserHibernation(.aggressive) }),
        ("layout.panePadding", 0, { try await $0.setPanePadding(0) }),
        ("layout.paneCornerRadius", 8, { try await $0.setPaneCornerRadius(8) }),
        ("layout.paneBorder", "none", { try await $0.setPaneBorder(PaneBorderStyle.none) }),
        ("layout.paneBorderWidth", 2, { try await $0.setPaneBorderWidth(2) }),
        ("layout.paneBorderColor", "#112233", { try await $0.setPaneBorderColor("#112233") }),
    ]

    @Test func everyTypedSetterWritesThroughTheValidatedPath() async throws {
        let (settings, url, directory) = try make()
        defer { try? FileManager.default.removeItem(at: directory) }
        for setter in Self.setters {
            let path = CmuxConfigFile.keyPath(from: setter.key)
            #expect(SettingsSchema.descriptor(for: path) != nil, "\(setter.key) is not a schema key")
            let before = settings.validatedWrites[setter.key, default: 0]
            try await setter.write(settings)
            #expect(settings.validatedWrites[setter.key, default: 0] == before + 1, "\(setter.key) bypassed setSetting")
            #expect(try document(url).value(at: path) == setter.value, "\(setter.key)")
        }
    }

    /// Defaults remove their key, and the objects that removal empties, as before.
    @Test func defaultsRemoveTheirKeys() async throws {
        let (settings, url, directory) = try make()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await settings.setTitlebar(.standard)
        try await settings.setTitlebar(.minimal)
        try await settings.setShowBookmarksBar(true)
        try await settings.setShowBookmarksBar(false)
        try await settings.setPanePadding(0)
        try await settings.setPanePadding(nil)
        #expect(try document(url) == .object([:]))
        #expect(settings.validatedWrites["window.titlebar"] == 2)
    }

    @Test func aValueTheSchemaRefusesNeverReachesTheFile() async throws {
        let (settings, url, directory) = try make()
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: SettingRefused.self) { try await settings.setPanePadding(99) }
        await #expect(throws: SettingRefused.self) { try await settings.setPaneBorderColor("blue") }
        await #expect(throws: SettingRefused.self) { try await settings.setSetting(at: InterfaceSizeSetting().configPath, to: 40, by: .user) }
        await #expect(throws: SettingNotInSchema.self) { try await settings.setSetting(at: ["no", "suchKey"], to: true, by: .user) }
        #expect(try document(url) == .object([:]))
        #expect(settings.validatedWrites.isEmpty)
    }
}
