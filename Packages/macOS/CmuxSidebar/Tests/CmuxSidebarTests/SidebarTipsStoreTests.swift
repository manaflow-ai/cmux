import Foundation
import os
import SwiftUI
import Testing
@testable import CmuxSidebar

@MainActor
@Suite
struct SidebarTipsStoreTests {
    private let now = Date(timeIntervalSince1970: 1_791_417_600)

    @Test func dynamicPropertyUpdateDoesNotRequireTheMainActorExecutor() async throws {
        let name = "SidebarTipsStoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        // The test hands exclusive ownership to the detached task through this
        // lock, matching the repository's LiveSetting isolation regression.
        let property = OSAllocatedUnfairLock(
            uncheckedState: (SidebarTipsStore(defaults: defaults) as any DynamicProperty)
        )
        let didUpdate = await Task.detached {
            property.withLock { $0.update() }
            return true
        }.value
        #expect(didUpdate)
    }

    @Test func legacyOptOutAndHistorySurviveManualOpening() throws {
        let name = "SidebarTipsStoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "sidebarTips.hidden")
        defaults.set("a", forKey: "sidebarTips.currentTipID")
        defaults.set("a", forKey: "sidebarTips.seenTipIDs")
        let store = SidebarTipsStore(defaults: defaults)

        #expect(store.load().automaticTipsDisabled)
        #expect(store.load().lastOpenedAt == nil)
        store.open(tipIDs: ["a", "b"], now: now)
        let restored = SidebarTipsStore(defaults: defaults).load()
        #expect(restored.automaticTipsDisabled)
        #expect(restored.currentTipID == "b")
        #expect(restored.seenTipIDs == ["a", "b"])
        #expect(restored.lastOpenedAt == now)
        #expect(defaults.string(forKey: "sidebarTips.seenTipIDs") == "a,b")
    }

    @Test func separateViewsPreserveEachOthersSelectionsAndReminderAllowance() throws {
        let name = "SidebarTipsStoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let button = SidebarTipsStore(defaults: defaults)
        let popover = SidebarTipsStore(defaults: defaults)

        button.open(tipIDs: ["a", "b", "c"], now: now)
        popover.select("b")
        button.select("c")
        let restored = SidebarTipsStore(defaults: defaults).load()
        #expect(restored.currentTipID == "c")
        #expect(restored.seenTipIDs == ["a", "b", "c"])
        #expect(restored.lastOpenedAt == now)
        #expect(restored.lastOpenedDay == SidebarTipsSchedule().dayKey(for: now))
    }

    @Test func reenabledRemindersAndAutomaticSelectionUsePersistedState() throws {
        let name = "SidebarTipsStoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let button = SidebarTipsStore(defaults: defaults)
        let popover = SidebarTipsStore(defaults: defaults)

        popover.automaticTipsDisabled = true
        #expect(button.load().automaticTipsDisabled)
        popover.automaticTipsDisabled = false
        #expect(!button.load().automaticTipsDisabled)
        button.open(tipIDs: ["a", "b"], now: now, automaticTipID: "b")
        #expect(popover.load().currentTipID == "b")
        #expect(popover.load().seenTipIDs == ["b"])
        #expect(popover.load().lastOpenedAt == now)
    }

    @Test func manualRotationAndWeeklyRefresherPersistAcrossStoreInstances() throws {
        let name = "SidebarTipsStoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let tipIDs = ["a", "b", "c"]
        let schedule = SidebarTipsSchedule()

        for tipID in tipIDs {
            SidebarTipsStore(defaults: defaults).open(tipIDs: tipIDs, now: now)
            #expect(SidebarTipsStore(defaults: defaults).load().currentTipID == tipID)
        }
        let nextTime = now.addingTimeInterval(7 * 86_400)
        let store = SidebarTipsStore(defaults: defaults)
        let chosen = try #require(schedule.automaticTip(store.load(), tipIDs: tipIDs, now: nextTime))
        #expect(chosen == "a")
        store.open(tipIDs: tipIDs, now: nextTime, automaticTipID: chosen)
        let restored = SidebarTipsStore(defaults: defaults).load()
        #expect(restored.currentTipID == "a")
        #expect(restored.lastOpenedAt == nextTime)
        #expect(schedule.automaticTip(restored, tipIDs: tipIDs, now: nextTime.addingTimeInterval(86_400)) == nil)
    }

    @Test func injectedSuitesDoNotShareProgress() throws {
        let firstName = "SidebarTipsStoreTests.\(UUID())"
        let secondName = "SidebarTipsStoreTests.\(UUID())"
        let first = try #require(UserDefaults(suiteName: firstName))
        let second = try #require(UserDefaults(suiteName: secondName))
        defer {
            first.removePersistentDomain(forName: firstName)
            second.removePersistentDomain(forName: secondName)
        }

        SidebarTipsStore(defaults: first).open(tipIDs: ["a"], now: now)
        #expect(SidebarTipsStore(defaults: second).load() == SidebarTipsProgress())
    }
}
