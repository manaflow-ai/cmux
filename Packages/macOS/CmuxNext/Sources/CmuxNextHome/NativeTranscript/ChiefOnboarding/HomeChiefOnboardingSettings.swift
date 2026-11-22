import CmuxNextDesign
public import CmuxNextHomeModel
public import CmuxNextSettings
import Foundation

/// Meet Chief's settings (``ChiefOnboardingSettings``) in the app: cmux-next.json through the app's
/// ``SettingsController``, each write the person's own (``SettingWriter/user``), as the Settings window makes it.
/// Every read is the controller's observable snapshot, so the card follows a change made in Settings, by
/// `cmux settings set` or in the file. With no settings loaded yet it reads the defaults and refuses writes.
///
/// ```swift
/// ChiefOnboarding(defaults: .standard, settings: HomeChiefOnboardingSettings { [weak services] in services?.settings })
/// ```
@MainActor
public final class HomeChiefOnboardingSettings: ChiefOnboardingSettings {
    private let controller: @MainActor () -> SettingsController?

    /// The settings this Mac's Chief host reads at each turn (`chief.permissionMode`).
    static let modePath = ["chief", "permissionMode"]

    /// - Parameter controller: The app's settings, once loaded (`AppServices.settings`).
    public init(controller: @escaping @MainActor () -> SettingsController?) {
        self.controller = controller
    }

    private struct NotLoaded: Error {}

    private func loaded() throws -> SettingsController {
        guard let settings = controller() else { throw NotLoaded() }
        return settings
    }

    public var mode: ChiefPermissionMode {
        controller()?.snapshot.root.value(at: Self.modePath)?.stringValue.flatMap(ChiefPermissionMode.init(rawValue:)) ?? .default
    }

    public var modeManaged: Bool { controller()?.managedKeys[Self.modePath.joined(separator: ".")] != nil }

    public func setMode(_ mode: ChiefPermissionMode) async throws {
        try await loaded().setSetting(at: Self.modePath, to: .string(mode.rawValue), by: .user)
    }

    public var density: ChiefOnboardingDensity? {
        guard let snapshot = controller()?.snapshot else { return .cozy }
        // A theme file's or a custom density wins over the built-in one: none of the three offered is in use.
        guard snapshot.themeDensity == nil, snapshot.customDensity == nil else { return nil }
        return ChiefOnboardingDensity(rawValue: snapshot.density ?? DensitySetting.fallback.rawValue)
    }

    public func setDensity(_ density: ChiefOnboardingDensity) async throws {
        let settings = try loaded()
        // The built-in density applies only once no custom one is picked (`CmuxConfigSnapshot.selectedDensity`).
        if settings.snapshot.customDensity != nil {
            try await settings.setSetting(at: CustomDensitySelectionSetting.configPath, to: nil, by: .user)
        }
        try await settings.setSetting(at: DensitySetting.configPath, to: .string(density.rawValue), by: .user)
    }

    public var textSize: Double {
        guard let snapshot = controller()?.snapshot else { return InterfaceSizeSetting.placeholder }
        // Unset, the text follows the density's own size.
        return snapshot.metrics["chromeFontSize"] ?? Double(snapshot.selectedDensity.bodySize)
    }

    public var textSizeRange: ClosedRange<Double> { InterfaceSizeSetting.range }

    public func setTextSize(_ points: Double) async throws {
        try await loaded().setSetting(at: InterfaceSizeSetting.configPath, to: .number(points), by: .user)
    }
}
