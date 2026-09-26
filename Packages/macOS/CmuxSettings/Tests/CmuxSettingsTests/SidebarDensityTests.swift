import Foundation
import Testing
@testable import CmuxSettings

@Suite("SidebarDensity")
struct SidebarDensityTests {
    private let sidebar = SidebarCatalogSection()

    private func withDefaults(_ body: (UserDefaults, UserDefaultsSettingsClient) throws -> Void) rethrows {
        let suiteName = "SidebarDensityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults, UserDefaultsSettingsClient(defaults: defaults))
    }

    @Test func fullDensityIsTheDefaultAndKeepsCatalogDefaults() {
        withDefaults { _, settings in
            #expect(settings.value(for: sidebar.density) == .full)
            #expect(settings.sidebarDetailValue(for: sidebar.showPorts) == true)
            #expect(settings.sidebarDetailValue(for: sidebar.showLog) == true)
            #expect(settings.sidebarNotificationMessageLineLimit() == sidebar.notificationMessageLineLimit.defaultValue)
        }
    }

    @Test func quietDensityHidesEveryUnsetDetailToggle() {
        withDefaults { _, settings in
            settings.set(.quiet, for: sidebar.density)
            let keys = [
                sidebar.showWorkspaceDescription, sidebar.showNotificationMessage, sidebar.showBranchDirectory,
                sidebar.showPullRequests, sidebar.showPorts, sidebar.showLog, sidebar.showProgress,
                sidebar.showCustomMetadata, sidebar.showSSH
            ]
            for key in keys {
                #expect(settings.sidebarDetailValue(for: key) == false, "\(key.id)")
            }
            // Attention signals are left alone.
            #expect(settings.sidebarDetailValue(for: sidebar.showAgentActivity) == true)
        }
    }

    @Test func explicitlyStoredToggleWinsOverDensity() {
        withDefaults { _, settings in
            settings.set(.quiet, for: sidebar.density)
            settings.set(true, for: sidebar.showPorts)
            #expect(settings.sidebarDetailValue(for: sidebar.showPorts) == true)
            #expect(settings.sidebarDetailValue(for: sidebar.showLog) == false)

            settings.set(.full, for: sidebar.density)
            settings.set(false, for: sidebar.showLog)
            #expect(settings.sidebarDetailValue(for: sidebar.showLog) == false)
        }
    }

    @Test func compactDensityHidesLogAndShortensNotificationPreview() {
        withDefaults { _, settings in
            settings.set(.compact, for: sidebar.density)
            #expect(settings.sidebarDetailValue(for: sidebar.showLog) == false)
            #expect(settings.sidebarDetailValue(for: sidebar.showPorts) == true)
            #expect(settings.sidebarNotificationMessageLineLimit() == 2)

            settings.set(6, for: sidebar.notificationMessageLineLimit)
            #expect(settings.sidebarNotificationMessageLineLimit() == 6)
        }
    }

    @Test func densityRawValuesMatchTheConfigSchema() {
        #expect(SidebarDensity.allCases.map(\.rawValue) == ["full", "compact", "quiet"])
        #expect(sidebar.density.id == "sidebar.density")
        #expect(sidebar.density.userDefaultsKey == "sidebarDensity")
    }
}
