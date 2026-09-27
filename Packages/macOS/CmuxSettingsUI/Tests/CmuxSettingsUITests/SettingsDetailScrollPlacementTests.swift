import SwiftUI
import Testing
@testable import CmuxSettingsUI

/// Where the one-pane-at-a-time settings detail scrolls for a navigation.
@MainActor
@Suite struct SettingsDetailScrollPlacementTests {
    @Test func openingASectionLandsAtTheTopOfTheScrollContent() {
        for section in SettingsSectionMountModel.displayOrder {
            let placement = SettingsDetailScrollPlacement.resolve(
                target: section,
                anchorID: "section:\(section.rawValue)"
            )
            #expect(placement == SettingsDetailScrollPlacement(
                anchorID: SettingsDetailScrollPlacement.topAnchorID,
                anchor: .top
            ), "\(section.rawValue)")
        }
    }

    @Test func subsectionPinsItsHeaderToTheTop() {
        let placement = SettingsDetailScrollPlacement.resolve(
            target: .browserImport,
            anchorID: "section:browserImport"
        )
        #expect(placement == SettingsDetailScrollPlacement(anchorID: "section:browserImport", anchor: .top))
    }

    @Test func settingRowIsCentered() {
        let placement = SettingsDetailScrollPlacement.resolve(
            target: .keyboardShortcuts,
            anchorID: "setting:keyboardShortcuts:shortcuts"
        )
        #expect(placement == SettingsDetailScrollPlacement(
            anchorID: "setting:keyboardShortcuts:shortcuts",
            anchor: .center
        ))
        let computers = SettingsDetailScrollPlacement.resolve(
            target: .mobile,
            anchorID: SettingsSectionID.computersSubsectionAnchorID
        )
        #expect(computers.anchor == .center)
    }

    @Test func restoreUsesTheSectionNeverAPersistedRow() {
        let restored = SettingsDetailScrollPlacement.restoreTarget(initialSection: nil, lastViewedSection: .app)
        #expect(restored.section == .app)
        #expect(restored.anchorID == "section:app")
        let targeted = SettingsDetailScrollPlacement.restoreTarget(initialSection: .browserImport, lastViewedSection: .app)
        #expect(targeted.section == .browserImport)
        #expect(targeted.anchorID == "section:browserImport")
    }
}

/// The App pane's agent list is loaded once per window, so revisits render
/// the final matrix height immediately.
@MainActor
@Suite struct NotificationSoundAgentCacheTests {
    @Test func loadsOnceAndKeepsTheResult() async {
        let cache = NotificationSoundAgentCache()
        var calls = 0
        let agent = NotificationSoundAgentOption(id: "claude", displayName: "Claude Code")
        await cache.loadIfNeeded {
            calls += 1
            return [agent]
        }
        await cache.loadIfNeeded {
            calls += 1
            return []
        }
        #expect(calls == 1)
        #expect(cache.agents == [agent])
    }

    @Test func anEmptyRegistryIsLoadedAgainOnTheNextRequest() async {
        let cache = NotificationSoundAgentCache()
        #expect(cache.agents == nil)
        await cache.loadIfNeeded { [] }
        #expect(cache.agents == [])
        let agent = NotificationSoundAgentOption(id: "codex", displayName: "Codex")
        await cache.loadIfNeeded { [agent] }
        #expect(cache.agents == [agent])
    }
}
