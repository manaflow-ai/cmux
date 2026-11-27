#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileWorkspaces

/// Settings → Needs You Look (the Mac's `notifications.attention.mark`): with Glow, a waiting
/// workspace row glows in place of its dot until this phone opens it; with Badge, the default,
/// no row ever glows. The glow keeps the row's size, and holds still under Reduce Motion.
@MainActor @Suite struct WorkspaceRowNeedsYouGlowTests {
    let activity = Date(timeIntervalSince1970: 1_000_000)
    nonisolated static let allStatuses: [WorkspaceStatus] = [.creating, .offline, .needsYou, .working, .done, .idle]

    @Test func theListReadsTheSettingsKey() {
        #expect(CmuxMobilePreferences.Key.attentionMark == "cmuxMobile.settings.attentionMark")
    }

    @Test(arguments: allStatuses) func badgeNeverGlows(status: WorkspaceStatus) {
        #expect(!WorkspaceRow.glows(status: status, look: .badge, seenAt: nil, lastActivityAt: activity))
    }

    @Test func glowLightsOnlyRowsThatWaitForThePerson() {
        for status in Self.allStatuses {
            let glows = WorkspaceRow.glows(status: status, look: .glow, seenAt: nil, lastActivityAt: activity)
            #expect(glows == (status == .needsYou || status == .done), "\(status)")
        }
    }

    @Test func anOpenedRowStopsGlowingUntilNewActivity() {
        let opened = activity.addingTimeInterval(5)
        #expect(!WorkspaceRow.glows(status: .needsYou, look: .glow, seenAt: opened, lastActivityAt: activity))
        // Opened before its latest activity: it waits unseen again.
        let earlier = activity.addingTimeInterval(-5)
        #expect(WorkspaceRow.glows(status: .needsYou, look: .glow, seenAt: earlier, lastActivityAt: activity))
    }

    @Test func theGlowTakesTheDotsColor() {
        #expect(WorkspaceRow.glowColor(.needsYou) != nil)
        #expect(WorkspaceRow.glowColor(.done) != nil)
        #expect(WorkspaceRow.glowColor(.working) == nil)
        #expect(WorkspaceRow.glowColor(.idle) == nil)
    }

    /// The dot only goes transparent: a glowing row is exactly as tall as its badge row.
    @Test(arguments: [WorkspaceStatus.needsYou, .done]) func glowKeepsTheRowsSize(status: WorkspaceStatus) {
        let ws = Workspace(id: "ws-1", macID: "mac-1", title: "scratch", directory: "~/src", branch: "main",
                           tabs: [], lastActivityAt: activity)
        func height(_ row: WorkspaceRow) -> CGFloat {
            UIHostingController(rootView: row).sizeThatFits(in: CGSize(width: 390, height: 1000)).height
        }
        #expect(height(WorkspaceRow(workspace: ws, status: status, glows: true)) == height(WorkspaceRow(workspace: ws, status: status)))
    }

    @Test func reduceMotionHoldsTheGlowStill() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 100))
        let view = NeedsYouGlowView(frame: CGRect(x: 0, y: 0, width: 300, height: 60))
        window.addSubview(view)
        view.configure(color: .systemYellow, breathes: false)
        #expect(view.layer.animation(forKey: NeedsYouGlowView.breathKey) == nil)
        view.configure(color: .systemYellow, breathes: true)
        #expect(view.layer.animation(forKey: NeedsYouGlowView.breathKey) != nil)
        view.configure(color: .systemYellow, breathes: false)
        #expect(view.layer.animation(forKey: NeedsYouGlowView.breathKey) == nil)
    }
}
#endif
