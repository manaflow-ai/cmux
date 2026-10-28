import CmuxNextActions
import CmuxNextAppearance
@testable import CmuxNextSettings
import Foundation
import Testing

/// The Passwords switches in Settings (cmux-next-spec PASSWORDS, cx-d0d.13):
/// `browser.passwords.offerToSave`, `.generate` and `.allowExport` are schema
/// keys the person sets, and no agent may change them, since they decide
/// whether sign-ins are kept and whether every password can leave as a file.
@MainActor @Suite(.serialized) struct BrowserPasswordsSettingTests {
    static let keys = [["browser", "passwords", "offerToSave"], ["browser", "passwords", "generate"],
                       ["browser", "passwords", "allowExport"]]

    static func settings(_ json: String = "{}", managed: ManagedPreferences = ManagedPreferences()) throws -> (SettingsController, URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-passwords-setting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(registry: .standard(), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(managed),
                                          managedWatchFiles: [])
        return (settings, home)
    }

    @Test func thePersonSetsThePasswordSwitchesAndAgentsCannot() async throws {
        let (settings, home) = try Self.settings()
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()

        for path in Self.keys {
            await #expect(throws: SettingUserOnly.self) {
                try await settings.setSetting(at: path, to: .bool(true), by: .caller("mcp"))
            }
            await #expect(throws: SettingRefused.self) {
                try await settings.setSetting(at: path, to: .string("yes"), by: .user)
            }
        }
        try await settings.setSetting(at: ["browser", "passwords", "allowExport"], to: .bool(true), by: .user)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appending(path: "cmux-next.json"))) as? [String: Any]
        let passwords = (saved?["browser"] as? [String: Any])?["passwords"] as? [String: Any]
        #expect(passwords?["allowExport"] as? Bool == true)
    }

    /// A managed (MDM or team) value decides over the person's file, as the Settings window shows
    /// it: a forced export off holds even when cmux.json says on, and a recommended value applies
    /// when the file has none (#20058 review).
    @Test func managedPolicyDecidesWhatTheAppApplies() async throws {
        let (settings, home) = try Self.settings(#"{ "browser": { "passwords": { "allowExport": true } } }"#, managed: ManagedPreferences(
            forced: ["browser.passwords.allowExport": .bool(false)], recommended: ["browser.passwords.offerToSave": .bool(false)]))
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()

        let current = BrowserPasswordsSetting.current(settings)
        #expect(!current.allowExport)
        #expect(!current.offerToSave)
        #expect(current.generate)
    }
}
