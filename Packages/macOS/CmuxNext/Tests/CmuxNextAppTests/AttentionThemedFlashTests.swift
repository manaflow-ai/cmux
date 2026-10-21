import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextSettings
import Testing

/// Leo (2026-10-21): "I don't think we should have blinky on turn end for GUI... and if we have
/// any kind of blinky, it should be themed/customizable." The attention ring and its flash take
/// the theme accent (or `notifications.attention.color`), never a fixed blue; terminal panes ring
/// and agent chat panes do not by default (`notifications.attention.terminals`, `agentChats`);
/// `ringStyle` is glow, ring or none; `blinkCount` sets the flashes; Reduce Motion is static.
@MainActor @Suite(.serialized) struct AttentionThemedFlashTests {
    static let notificationBlue = [57, 130, 245]

    static func rgb(_ color: CGColor?) -> [Int] {
        guard let color else { return [] }
        let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? color
        return (srgb.components ?? []).prefix(3).map { Int(($0 * 255).rounded()) }
    }

    static func withAttention(_ change: (inout AttentionSettings) -> Void, _ body: () throws -> Void) rethrows {
        let design = DesignSettings.shared
        let before = design.attention
        defer { design.attention = before }
        var settings = AttentionSettings()
        change(&settings)
        design.attention = settings
        try body()
    }

    /// One pane showing a terminal tab with an unread notification, or an agent chat whose turn ended.
    static func workspace(agentChat: Bool) throws -> (NotificationCenterService, WorkspaceModel) {
        _ = NSApplication.shared
        var tab: TabSnapshot
        if agentChat {
            tab = TabSnapshot(surface: SurfaceID(rawValue: 1), kind: .conversation, cwd: nil)
            tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:themed", session: "s1", harness: "claude"))
        } else {
            let marker = TabNotification(notification: NotificationID(rawValue: 5), unread: true, level: .info, source: "terminal")
            tab = TabSnapshot(surface: 1, terminalResourceID: "term_5", notification: marker)
        }
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [tab])])
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let service = NotificationCenterService()
        if agentChat { service.agentTurnEnded(session: "s1", in: store.workspaces) }
        return (service, try #require(store.workspaces.first))
    }

    static func overlay() -> PaneOverlayView {
        let view = PaneOverlayView()
        view.setFrameSize(NSSize(width: 400, height: 300))
        return view
    }

    static func update(_ view: PaneOverlayView, _ mark: AttentionMark?, _ settings: AttentionSettings, readByEntry: Bool = false) {
        view.update(showsRing: false, dim: 0, focusRing: FocusRingSettings(), border: PaneOverlayView.Border(shows: false),
                    attention: mark, attentionSettings: settings, readByEntry: readByEntry, animated: true)
    }

    static func opacities(_ animation: CAAnimation?) -> [Float] {
        ((animation as? CAKeyframeAnimation)?.values ?? []).compactMap { ($0 as? NSNumber)?.floatValue }
    }

    @Test func theDefaultsRingTerminalsNotAgentChatsInTheThemeAccent() {
        let settings = AttentionSettings()
        #expect(settings.ringsTerminals && !settings.ringsAgentChats)
        #expect(settings.ringStyle == .glow && settings.color == nil && settings.blinkCount == 2)
        #expect(settings.rings(agentChat: false) && !settings.rings(agentChat: true))
    }

    @Test func anAgentPaneTurnEndDoesNothingByDefault() throws {
        try Self.withAttention({ _ in }) {
            let (service, workspace) = try Self.workspace(agentChat: true)
            #expect(service.attentionMarks(for: workspace).isEmpty, "an agent chat's turn end rang its pane")
        }
    }

    /// A terminal's ring and its dismiss flash draw the theme accent, not the notification blue.
    @Test func aTerminalFlashesInTheAccent() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        try Self.withAttention({ _ in }) {
            let (service, workspace) = try Self.workspace(agentChat: false)
            let mark = try #require(service.attentionMarks(for: workspace).values.first, "the terminal did not ring")
            let view = Self.overlay()
            Self.update(view, mark, AttentionSettings())
            #expect(Self.rgb(view.attentionLayer.borderColor) == Self.rgb(Palette.accentFill.cgColor))
            #expect(Self.rgb(view.attentionLayer.borderColor) != Self.notificationBlue, "the terminal ring is the fixed blue")
            Self.update(view, nil, AttentionSettings(), readByEntry: true)
            #expect(view.attentionLayer.animation(forKey: "attention-dismiss") != nil, "the terminal ring did not flash out")
            #expect(Self.rgb(view.attentionLayer.borderColor) != Self.notificationBlue, "the flash is the fixed blue")
        }
    }

    /// A picked color wins over the accent.
    @Test func aPickedColorWins() {
        var settings = AttentionSettings()
        settings.color = ThemeRGB(hex: 0x33AA55)
        let view = Self.overlay()
        Self.update(view, AttentionMark(generation: 3), settings)
        #expect(Self.rgb(view.attentionLayer.borderColor) == [0x33, 0xAA, 0x55])
    }

    /// `ringStyle` none: no pane gets a mark and the overlay draws no ring layer, so nothing flashes.
    @Test func ringStyleNoneDrawsNoRing() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        try Self.withAttention({ $0.ringStyle = .none }) {
            let (service, workspace) = try Self.workspace(agentChat: false)
            #expect(service.attentionMarks(for: workspace).isEmpty, "ring style none still marked the pane")
        }
        var settings = AttentionSettings()
        settings.ringStyle = .none
        let view = Self.overlay()
        Self.update(view, AttentionMark(generation: 3), settings)
        #expect(view.attentionLayer.opacity == 0)
        #expect(view.attentionLayer.animationKeys() == nil, "ring style none animated the ring")
        Self.update(view, nil, settings, readByEntry: true)
        #expect(view.attentionLayer.animationKeys() == nil, "ring style none flashed")
    }

    /// `ringStyle` ring: the stroke alone, with no glow at rest or in the flash; glow keeps classic's.
    @Test func ringStyleRingHasNoGlow() {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        var settings = AttentionSettings()
        settings.ringStyle = .ring
        let view = Self.overlay()
        Self.update(view, AttentionMark(generation: 3), settings)
        #expect(view.attentionGlow.opacity == 0)
        Self.update(view, nil, settings, readByEntry: true)
        #expect(view.attentionLayer.animation(forKey: "attention-dismiss") != nil, "the ring did not flash out")
        #expect(view.attentionDismissGlow == nil, "the ring style glowed in its flash")
        let glowing = Self.overlay()
        Self.update(glowing, AttentionMark(generation: 3), AttentionSettings())
        #expect(glowing.attentionGlow == PaneOverlayView.Glow.ring)
    }

    /// `blinkCount` 1 or 2: the dismiss flash blinks that many times and ends with no ring.
    @Test(arguments: [1, 2])
    func theFlashCountIsHonoured(_ count: Int) throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        var settings = AttentionSettings()
        settings.blinkCount = count
        let view = Self.overlay()
        Self.update(view, AttentionMark(generation: 3), settings)
        Self.update(view, nil, settings, readByEntry: true)
        let values = Self.opacities(try #require(view.attentionLayer.animation(forKey: "attention-dismiss"), "no flash"))
        let blinks = zip(values, values.dropFirst()).filter { $0 > 0 && $1 == 0 }.count
        #expect(blinks == count, "\(blinks) blinks, want \(count): \(values)")
        #expect(values.last == 0)
    }

    /// Reduce Motion: the ring shows static at its rest, with no arrival animation and no flash out.
    @Test func reduceMotionIsStatic() {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let settings = AttentionSettings()
        let view = Self.overlay()
        Self.update(view, AttentionMark(generation: 3), settings)
        #expect(view.attentionLayer.opacity > 0, "the ring does not show under Reduce Motion")
        #expect(view.attentionLayer.animation(forKey: "attention") == nil, "the ring animated in under Reduce Motion")
        Self.update(view, nil, settings, readByEntry: true)
        #expect(view.attentionLayer.animation(forKey: "attention-dismiss") == nil, "the ring flashed under Reduce Motion")
    }

    @Test func theSettingsLoadFromCmuxJSONAndShowInSettings() throws {
        let root: CmuxNextSettings.JSONValue = .object(["notifications": .object(["attention": .object([
            "ringStyle": .string("ring"), "terminals": .bool(false), "agentChats": .bool(true),
        ])])])
        let parsed = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: []).attention
        #expect(parsed.ringStyle == .ring && !parsed.ringsTerminals && parsed.ringsAgentChats)
        let rows: [(String, CmuxNextSettings.JSONValue)] = [("ringStyle", .string("glow")), ("terminals", .bool(true)), ("agentChats", .bool(false))]
        for (key, value) in rows {
            let row = try #require(SettingsSchema.descriptor(for: ["notifications", "attention", key]), "no \(key) row")
            #expect(row.defaultValue == value, "\(key) defaults to \(String(describing: row.defaultValue))")
        }
    }
}
