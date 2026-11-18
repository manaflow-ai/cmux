import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// User 2026-11-17 (msg 38388): "minimal mode should hide everything in sidebar including cards like update, iff user
/// is not hovered in sidebar". In Minimal Mode, with the pointer away, every piece of sidebar chrome fades out: the
/// controls, and also the cards (Restart to Update, notices, Now Playing, cmux Updated), the card stack, app health's
/// line, the Update Available button, the Priority bell, the titlebar accessory and the needs-you tray. One rule
/// covers them: every sidebar view but the content (the list, the bands, the Priority view, edit mode's bar) fades,
/// so a card added later hides by default. The pointer over the sidebar shows them all. A fade only: each keeps its
/// frame and its place in the accessibility tree.
@MainActor @Suite(.serialized) struct MinimalModeHidesEverythingTests {
    /// The chrome that stayed on screen in Minimal Mode with the pointer away, before the shared rule.
    private static func leakers(_ sidebar: SidebarView, extra: NSView) -> [(String, NSView)] {
        [("update card", sidebar.updateCardView), ("notice card", sidebar.noticeCardView),
         ("now playing card", sidebar.nowPlayingCardView), ("updated card", sidebar.updatedCardView),
         ("card stack", sidebar.footerCards!), ("health line", sidebar.healthIndicator!),
         ("update available", sidebar.updateAvailableButton), ("priority bell", sidebar.priorityButton),
         ("titlebar accessory", sidebar.titlebarAccessory!), ("needs-you tray", sidebar.needsYouTray),
         ("a view added later", extra)]
    }

    private static func dress(_ sidebar: SidebarView) -> NSView {
        sidebar.footerCards = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        sidebar.healthIndicator = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 16))
        sidebar.titlebarAccessory = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        sidebar.showUpdateAvailable("Update Available")
        sidebar.showPriority(SidebarPriorityPanel(entries: []))
        sidebar.updateCardView.configure(SidebarUpdateCard(title: "Update Ready", detail: "nightly", buttonTitle: "Restart to Update",
                                                           automaticUpdatesTitle: "Automatic Updates", automaticUpdates: true,
                                                           notes: .init(headline: "Update Ready", keepsRunning: "")))
        // A card a later change adds straight to the sidebar: hidden by default, no per-card wiring.
        let extra = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        sidebar.addSubview(extra)
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
        return extra
    }

    @Test func minimalModeHidesEveryCardAndControlWithThePointerAway() async throws {
        let previousMotion = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = previousMotion }
        let h = try await SidebarBandHideTests().make(#"{"sidebar":{"minimal":true}}"#)
        defer { h.tearDown() }
        await h.until { h.sidebar.design.sidebarSections.minimal }
        let extra = Self.dress(h.sidebar)
        h.sidebar.setChromeRevealed(false)
        h.sidebar.needsLayout = true
        h.sidebar.layoutSubtreeIfNeeded()
        let shown = Self.leakers(h.sidebar, extra: extra).filter { $0.1.alphaValue > 0 }.map(\.0)
        #expect(shown.isEmpty, "Minimal Mode at rest still shows: \(shown)")
        // A fade, never a hide: VoiceOver and the keyboard still reach them.
        #expect(!h.sidebar.updateCardView.isHidden && !h.sidebar.updateAvailableButton.isHidden)
        // The list itself stays.
        #expect(h.sidebar.edgeFade.alphaValue == 1)

        h.sidebar.setChromeRevealed(true)
        h.sidebar.needsLayout = true
        h.sidebar.layoutSubtreeIfNeeded()
        let hidden = Self.leakers(h.sidebar, extra: extra).filter { $0.1.alphaValue < 1 }.map(\.0)
        #expect(hidden.isEmpty, "the pointer over the sidebar still hides: \(hidden)")
    }

    /// A card that arrives while the pointer is away arrives hidden.
    @Test func aCardArrivingWithThePointerAwayStaysHidden() async throws {
        let previousMotion = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = previousMotion }
        let h = try await SidebarBandHideTests().make(#"{"sidebar":{"minimal":true}}"#)
        defer { h.tearDown() }
        await h.until { h.sidebar.design.sidebarSections.minimal }
        h.sidebar.setChromeRevealed(false)
        let extra = Self.dress(h.sidebar)
        let shown = Self.leakers(h.sidebar, extra: extra).filter { $0.1.alphaValue > 0 }.map(\.0)
        #expect(shown.isEmpty, "arrived visible with the pointer away: \(shown)")
    }

    /// Off by default, and the older Show Sidebar Controls Only on Hover hides only its controls: cards show.
    @Test func withoutMinimalModeTheCardsShow() async throws {
        let previousMotion = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = previousMotion }
        for json in ["{}", #"{"sidebar":{"controlsOnHover":true}}"#] {
            let h = try await SidebarBandHideTests().make(json)
            defer { h.tearDown() }
            let extra = Self.dress(h.sidebar)
            h.sidebar.setChromeRevealed(false)
            h.sidebar.needsLayout = true
            h.sidebar.layoutSubtreeIfNeeded()
            let hidden = Self.leakers(h.sidebar, extra: extra).filter { $0.1.alphaValue < 1 }.map(\.0)
            #expect(hidden.isEmpty, "\(json) hid: \(hidden)")
        }
    }

    @Test func theRuleHidesTheRestOnlyInMinimalMode() {
        let rest = SidebarChromeReveal(revealed: false, minimalMode: .off, controlsOnHover: true, spacesVisibility: .hover, minimal: true)
        #expect(rest.rest == 0)
        #expect(SidebarChromeReveal(revealed: true, minimalMode: .off, controlsOnHover: true, spacesVisibility: .hover, minimal: true).rest == 1)
        #expect(SidebarChromeReveal(revealed: false, minimalMode: .off, controlsOnHover: true, spacesVisibility: .hover).rest == 1)
    }

    /// The faded cards' room goes to the list with the footer's (as ``MinimalModeFooterCollapseTests``); the pointer
    /// back over the sidebar gives it back.
    @Test func theHiddenCardsRoomGoesToTheList() async throws {
        let previousMotion = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = previousMotion }
        let h = try await SidebarBandHideTests().make(#"{"sidebar":{"minimal":true}}"#)
        defer { h.tearDown() }
        await h.until { h.sidebar.design.sidebarSections.minimal }
        _ = Self.dress(h.sidebar)
        func listBottom(revealed: Bool) -> CGFloat {
            h.sidebar.setChromeRevealed(revealed)
            h.sidebar.needsLayout = true
            h.sidebar.layoutSubtreeIfNeeded()
            return h.sidebar.edgeFade.frame.maxY
        }
        let shown = listBottom(revealed: true)
        let card = h.sidebar.updateCardView.frame
        #expect(card.height > 0, "fixture: the update card has the slot")
        #expect(shown <= card.minY + 0.5, "revealed, the list ends above the card: list \(shown), card \(card)")
        let rest = listBottom(revealed: false)
        #expect(rest >= card.maxY, "at rest the list takes the hidden card's room: list \(rest), card \(card)")
        #expect(abs(listBottom(revealed: true) - shown) <= 0.5, "the pointer back gives the room back")
    }
}
