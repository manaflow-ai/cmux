import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextSettings
import Foundation
import Testing

/// Unread rings from classic (Lawrence, 2026-10-20): what classic's ring and dismiss flash had
/// beyond the blink-out of #22678. `notifications.attention.flash` (classic
/// `notifications.paneFlash`) turns the dismiss flash off and `flashOnTyping` (classic
/// `paneFlashOnTyping`) keeps typing from flashing; the ring and the flash glow as classic's did
/// (0.35 opacity, 3 pt at rest; 0.6, 6 pt in the flash); the color defaults to the theme accent
/// (Leo, 2026-10-21: themed, never a fixed blue).
@MainActor @Suite(.serialized) struct UnreadRingClassicFlashTests {
    static func unreadTab() throws -> (NotificationCenterService, TabModel) {
        _ = NSApplication.shared
        let store = DaemonStore()
        let marker = TabNotification(notification: NotificationID(rawValue: 4), unread: true, level: .info, source: "agent")
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_7", notification: marker)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let tab = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        return (NotificationCenterService(), tab)
    }

    static func withAttention(_ change: (inout AttentionSettings) -> Void, _ body: () throws -> Void) rethrows {
        let design = DesignSettings.shared
        let before = design.attention
        defer { design.attention = before }
        change(&design.attention)
        try body()
    }

    @Test(arguments: [NotificationTrigger.click, .keystroke, .open])
    func goingIntoThePaneFlashesByDefault(_ trigger: NotificationTrigger) throws {
        try Self.withAttention({ _ in }) {
            let (service, tab) = try Self.unreadTab()
            service.interacted(trigger, tab: tab)
            #expect(service.entryReads.contains(tab.id), "\(trigger) read the pane without its flash")
        }
    }

    @Test(arguments: [NotificationTrigger.click, .keystroke, .open])
    func theFlashSettingTurnsItOff(_ trigger: NotificationTrigger) throws {
        try Self.withAttention({ $0.flashesOnRead = false }) {
            let (service, tab) = try Self.unreadTab()
            service.interacted(trigger, tab: tab)
            #expect(service.log.contains("ack \(tab.id)"), "\(trigger) did not read the pane")
            #expect(!service.entryReads.contains(tab.id), "\(trigger) flashed with the flash off")
        }
    }

    @Test func typingFlashesOnlyWithFlashOnTyping() throws {
        try Self.withAttention({ $0.flashesOnTyping = false }) {
            let (typed, typedTab) = try Self.unreadTab()
            typed.interacted(.keystroke, tab: typedTab)
            #expect(!typed.entryReads.contains(typedTab.id), "typing flashed with flashOnTyping off")
            let (clicked, clickedTab) = try Self.unreadTab()
            clicked.interacted(.click, tab: clickedTab)
            #expect(clicked.entryReads.contains(clickedTab.id), "flashOnTyping off stopped a click's flash")
        }
    }

    @Test func theSettingsLoadFromCmuxJSON() {
        let defaults = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: []).attention
        #expect(defaults.flashesOnRead && defaults.flashesOnTyping)
        #expect(defaults.color == nil, "a ring color is set by default (nil takes the theme accent)")
        let root: CmuxNextSettings.JSONValue = .object(["notifications": .object(["attention": .object([
            "flash": .bool(false), "flashOnTyping": .bool(false), "color": .string("#FF8800"),
        ])])])
        let parsed = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: []).attention
        #expect(!parsed.flashesOnRead && !parsed.flashesOnTyping)
        #expect(parsed.color == ThemeRGB(hex: 0xFF8800))
    }

    @Test func theSettingsShowInSettings() throws {
        for key in ["flash", "flashOnTyping"] {
            let row = try #require(SettingsSchema.descriptor(for: ["notifications", "attention", key]), "no \(key) row")
            #expect(row.defaultValue == .bool(true))
        }
    }

    /// The ring and its flash default to the theme accent, never the notification blue.
    @Test func theRingDefaultsToTheThemeAccent() {
        #expect(AttentionHighlightLook.subtle.defaultColor == Palette.accentFill)
    }

    @Test func theRingAndItsFlashGlowAsClassicsDid() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let view = PaneOverlayView()
        view.setFrameSize(NSSize(width: 400, height: 300))
        func update(_ mark: AttentionMark?, readByEntry: Bool) {
            view.update(showsRing: false, dim: 0, focusRing: FocusRingSettings(), border: PaneOverlayView.Border(shows: false),
                        attention: mark, attentionSettings: AttentionSettings(), readByEntry: readByEntry, animated: true)
        }
        update(AttentionMark(generation: 7), readByEntry: false)
        #expect(view.attentionGlow == PaneOverlayView.Glow(opacity: 0.35, radius: 3))
        #expect(view.attentionGlowColor == Palette.accentFill.cgColor)
        update(nil, readByEntry: true)
        #expect(view.attentionDismissGlow == PaneOverlayView.Glow(opacity: 0.6, radius: 6), "the flash does not glow stronger")
    }

    /// A source's own ring color (`notifications.sources.<source>.color`) stays through the flash.
    @Test func theFlashKeepsTheSourceColor() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let view = PaneOverlayView()
        view.setFrameSize(NSSize(width: 400, height: 300))
        let orange = ThemeRGB(hex: 0xFF8800)
        func update(_ mark: AttentionMark?, readByEntry: Bool) {
            view.update(showsRing: false, dim: 0, focusRing: FocusRingSettings(), border: PaneOverlayView.Border(shows: false),
                        attention: mark, attentionSettings: AttentionSettings(), readByEntry: readByEntry, animated: true)
        }
        update(AttentionMark(color: orange, generation: 7), readByEntry: false)
        update(nil, readByEntry: true)
        #expect(view.attentionGlowColor == orange.nsColor.cgColor, "the flash took the default color")
    }
}
