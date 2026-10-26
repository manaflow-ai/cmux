import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSettings
import CmuxNextSettingsWindow
import Foundation
import Testing

/// Help > Feature Flags (`help.featureFlags`, `cmux action run help.featureFlags`):
/// cmux-next's feature flags are the Labs toggles (`labs.*`), so the action
/// opens Settings > Advanced > Labs instead of showing a greyed-out reason.
@MainActor @Suite(.serialized)
struct FeatureFlagsActionTests {
    @Test func featureFlagsIsAvailableAndAimsAtTheLabsGroup() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        #expect(services.registry.unavailableReason(for: "help.featureFlags") == nil, "Feature Flags is still greyed out")
        let anchor = try #require(SettingsAnchor(key: FeatureFlagsPage.settingKey))
        #expect(anchor.section == .advanced)
        // Without a loaded cmux.json the run says why instead of doing nothing.
        services.settings = nil
        let refusal = services.registry.capturingRefusal {
            _ = services.registry.perform("help.featureFlags", invocation: ActionInvocation())
        }
        #expect(refusal != nil)
    }
}
