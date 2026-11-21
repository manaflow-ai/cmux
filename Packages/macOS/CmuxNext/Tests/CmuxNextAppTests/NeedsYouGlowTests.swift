import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxNextSettings
import Testing

/// Leo 2026-11-19: "needs you" as motion, "some of them maybe just as customizations lol if it affects default
/// looks". A waiting tab and sidebar row glow gently until seen, instead of the badge, behind
/// `notifications.attention.mark` `glow`; the badge stays the default (Lawrence keeps defaults).
@MainActor @Suite(.serialized) struct NeedsYouGlowTests {
    private func withLook<T>(_ look: AttentionMarkLook, loops: Bool = true, _ body: () throws -> T) rethrows -> T {
        let attention = DesignSettings.shared.attention
        let speed = DesignSettings.shared.animationSpeed
        DesignSettings.shared.attention.mark = look
        DesignSettings.shared.animationSpeed = .normal
        Motion.reduceMotionOverride = !loops
        defer {
            DesignSettings.shared.attention = attention
            DesignSettings.shared.animationSpeed = speed
            Motion.reduceMotionOverride = nil
        }
        return try body()
    }

    private func laidOutCell(_ item: TabItem) -> TabCell {
        let cell = TabCell(item: item)
        cell.frame = CGRect(x: 0, y: 0, width: 200, height: 30)
        return cell
    }

    @Test func theBadgeIsTheDefault() {
        #expect(AttentionSettings().mark == .badge)
        #expect(AttentionSettings.markDefault == .badge)
        #expect(CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: []).attention.mark == .badge)
    }

    @Test func theGlowLoadsFromCmuxJSONAndShowsInSettings() throws {
        let root: CmuxNextSettings.JSONValue = .object(["notifications": .object(["attention": .object(["mark": .string("glow")])])])
        #expect(CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: []).attention.mark == .glow)
        let row = try #require(SettingsSchema.descriptor(for: ["notifications", "attention", "mark"]))
        #expect(row.defaultValue == .string("badge"))
    }

    @Test func aWaitingTabKeepsItsBadgeByDefault() {
        withLook(.badge) {
            let cell = laidOutCell(TabItem(id: TabID("t"), title: "Chat", isUnread: true))
            #expect(cell.badgeLayer != nil)
            #expect(cell.needsYouGlowLayer == nil)
        }
    }

    @Test func aWaitingTabGlowsInPlaceOfItsBadgeUntilSeen() throws {
        try withLook(.glow) {
            let cell = laidOutCell(TabItem(id: TabID("t"), title: "Chat", isUnread: true))
            let glow = try #require(cell.needsYouGlowLayer, "an unseen waiting tab glows")
            #expect(cell.badgeLayer == nil, "the glow replaces the badge")
            #expect(glow.frame == cell.pillFrameInCell)
            let breath = try #require(glow.animation(forKey: TabCell.needsYouGlowKey), "the glow breathes")
            // An endless breath recomposited the window at full refresh: 24 % WindowServer CPU, 6 % GPU (idle_attention).
            #expect(breath.repeatCount == 3, "a few breaths, then the halo rests at no frame cost")
            #expect(breath.preferredFrameRateRange.maximum <= 30)
            cell.isSelected = true
            #expect(cell.needsYouGlowLayer == nil, "a seen tab stops glowing")
            #expect(cell.badgeLayer != nil, "a seen tab that still waits shows its badge")
        }
    }

    @Test func aTabThatNeedsNothingNeverGlows() {
        withLook(.glow) {
            #expect(laidOutCell(TabItem(id: TabID("t"), title: "Chat")).needsYouGlowLayer == nil)
        }
    }

    @Test func theGlowHoldsStillWithoutLoopsOrOffScreen() throws {
        try withLook(.glow, loops: false) {
            let cell = laidOutCell(TabItem(id: TabID("t"), title: "Chat", isUnread: true))
            let glow = try #require(cell.needsYouGlowLayer, "Reduce Motion keeps the glow, steady")
            #expect(glow.animation(forKey: TabCell.needsYouGlowKey) == nil)
        }
        try withLook(.glow) {
            let cell = laidOutCell(TabItem(id: TabID("t"), title: "Chat", isUnread: true))
            cell.isWindowVisible = false
            let glow = try #require(cell.needsYouGlowLayer)
            #expect(glow.animation(forKey: TabCell.needsYouGlowKey) == nil, "a covered window costs no breath")
            cell.isWindowVisible = true
            #expect(glow.animation(forKey: TabCell.needsYouGlowKey) != nil)
        }
    }

    @Test func aRowGlowsForWhatItsBadgeAsksAndNotForWork() {
        func tone(_ unread: UnreadState, _ activity: StatusIndicatorState) -> StatusIndicatorState? {
            WorkspaceRowView.needsYouTone(WorkspaceRowBadges(unread: unread, activity: activity, detailed: false))
        }
        #expect(tone(.dot, .idle) == .success)
        #expect(tone(.none, .waiting(kind: .question)) == .waiting)
        #expect(tone(.dot, .error) == .error)
        #expect(tone(.none, .working) == nil)
        #expect(tone(.none, .idle) == nil)
    }
}
