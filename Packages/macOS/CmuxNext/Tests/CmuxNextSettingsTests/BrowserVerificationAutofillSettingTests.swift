import CmuxNextActions
import CmuxNextAppearance
@testable import CmuxNextSettings
import Foundation
import Testing

/// `browser.verificationAutofill.enabled` (plans/cmux-next/email-verification-autofill/DESIGN.md):
/// off unless the person turns it on, since it reads their mail; no agent may turn it on.
@MainActor @Suite(.serialized) struct BrowserVerificationAutofillSettingTests {
    static func settings(_ json: String = "{}") throws -> (SettingsController, URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-verify-autofill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(registry: .standard(), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()),
                                          managedWatchFiles: [])
        return (settings, home)
    }

    @Test func itIsOffByDefault() async throws {
        let (settings, home) = try Self.settings()
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()
        #expect(!BrowserVerificationAutofillSetting.current(settings).enabled)
    }

    @Test func thePersonTurnsItOnAndAgentsCannot() async throws {
        let (settings, home) = try Self.settings()
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()

        let path = BrowserVerificationAutofillSetting.enabledPath
        await #expect(throws: SettingUserOnly.self) {
            try await settings.setSetting(at: path, to: .bool(true), by: .caller("mcp"))
        }
        #expect(!BrowserVerificationAutofillSetting.current(settings).enabled)
        try await settings.setSetting(at: path, to: .bool(true), by: .user)
        #expect(BrowserVerificationAutofillSetting.current(settings).enabled)
    }

    @Test func aBadValueIsOffWithADiagnostic() {
        let root = JSONValue.object(["browser": .object(["verificationAutofill": .object(["enabled": .string("yes")])])])
        var diagnostics: [SettingsDiagnostic] = []
        #expect(!BrowserVerificationAutofillSetting.parse(root, diagnostics: &diagnostics).enabled)
        #expect(diagnostics.map(\.path) == ["browser.verificationAutofill.enabled"])
    }
}
