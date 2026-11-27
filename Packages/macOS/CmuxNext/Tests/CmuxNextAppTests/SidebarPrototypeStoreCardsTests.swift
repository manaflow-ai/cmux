import CmuxNextActions
@testable import CmuxNextApps
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextSidebar
import Foundation
import Testing
@testable import CmuxNextApp

/// Leo (2026-10-21): the sidebar prototypes are "not even, like, plugins. They're just toggles in the
/// app store area". Each card's Get writes its key, the sidebar's readers follow the key with the
/// Debug tunable off (as in Release), and Remove puts the key back to off.
@MainActor @Suite(.serialized) struct SidebarPrototypeStoreCardsTests {
    static let cards: [(id: String, reads: @MainActor () -> Bool)] = [
        ("sidebar.workspacesAsTabs", { SidebarTunables.workspacesAsTabsOn }),
        ("sidebar.chromeGroups", { SidebarTunables.groupChromeShapeOn }),
        ("sidebar.sideBySide", { SidebarTunables.multiViewOn }),
    ]

    @Test func eachCardTurnsItsSidebarFeatureOnAndOff() async throws {
        let (settings, home) = try await AppStoreFeaturesTests.make()
        defer { try? FileManager.default.removeItem(at: home) }
        let bridge = SettingsAppFeatures(settings: { settings })
        let saved = DesignSettings.shared.sidebarSections
        defer { DesignSettings.shared.sidebarSections = saved }
        for card in Self.cards {
            let feature = try AppStoreFeaturesTests.feature(card.id)
            #expect(feature.category == .sidebar)
            #expect(bridge.isAvailable(feature) && !bridge.isOn(feature), "\(card.id) is listed and off")
            try await bridge.set(feature, on: true)
            #expect(settings.fileRoot.value(at: feature.path) == .bool(true))
            DesignSettings.shared.sidebarSections = settings.snapshot.sidebarSections
            #expect(card.reads(), "\(card.id) reaches the sidebar with its Debug tunable off")
            try await bridge.set(feature, on: false)
            DesignSettings.shared.sidebarSections = settings.snapshot.sidebarSections
            #expect(!card.reads(), "\(card.id) Remove turns it off")
        }
    }
}
