import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
import CmuxNextOnboarding
import CmuxNextSettings
import Foundation
import Testing

/// D4 (cx-aha.1): the onboarding number keys choice writes cmux.json
/// through `ShortcutDigitScheme`, and Ctrl-1 follows it after the reload.
@MainActor @Suite struct OnboardingTabKeysWriteTests {
    func onboarding(_ text: String) async throws -> (AppOnboardingServices, AppServices, SettingsController, URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-onboarding-tabkeys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(text.utf8).write(to: url)
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url)
        services.settings = settings
        await settings.reload()
        return (AppOnboardingServices(owner: services.onboarding), services, settings, url, directory)
    }

    @Test func theAppOffersTheStep() async throws {
        let (onboarding, _, _, _, directory) = try await onboarding("{}")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(onboarding.offersTabKeys)
        #expect(await onboarding.currentTabKeys() == .tabs)
    }

    @Test func spacesMovesCtrlOneToSpacesAndTabsPutsItBack() async throws {
        let (onboarding, services, settings, url, directory) = try await onboarding(#"{"terminal": {"fontSize": 13}}"#)
        defer { try? FileManager.default.removeItem(at: directory) }
        onboarding.applyTabKeys(.spaces)
        await onboarding.flush()
        let root = try JSONC.parse(String(contentsOf: url, encoding: .utf8))
        #expect(root.value(at: ["shortcuts", "bindings", "space.selectByNumber"]) == "ctrl+1")
        #expect(root.value(at: ["shortcuts", "bindings", "selectSurfaceByNumber"]) == "ctrl+opt+1")
        #expect(root.value(at: ["terminal", "fontSize"]) == 13)
        await settings.reload()
        #expect(await onboarding.currentTabKeys() == .spaces)
        #expect(services.registry.effectiveShortcut(for: "space.selectByNumber") == Shortcut("1", modifiers: [.control]))

        onboarding.applyTabKeys(.tabs)
        await onboarding.flush()
        await settings.reload()
        #expect(await onboarding.currentTabKeys() == .tabs)
        #expect(services.registry.effectiveShortcut(for: "selectSurfaceByNumber") == Shortcut("1", modifiers: [.control]))
    }

    /// A Select Tab binding set by hand stays, and the step shows no choice.
    @Test func aHandBindingStays() async throws {
        let (onboarding, _, _, url, directory) = try await onboarding(#"{"shortcuts": {"bindings": {"selectSurfaceByNumber": "cmd+1"}}}"#)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await onboarding.currentTabKeys() == nil)
        onboarding.applyTabKeys(.spaces)
        await onboarding.flush()
        let root = try JSONC.parse(String(contentsOf: url, encoding: .utf8))
        #expect(root.value(at: ["shortcuts", "bindings", "selectSurfaceByNumber"]) == "cmd+1")
        #expect(root.value(at: ["shortcuts", "bindings", "space.selectByNumber"]) == "ctrl+1")
    }
}
