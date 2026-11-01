import AppKit
@testable import CmuxNextDesign
import CmuxNextIcons
@testable import CmuxNextSidebar
import CmuxTheme
import Testing

/// Leo 2026-10-19 on the sidebar session's hover card: "the styling, I'm not entirely sure that's
/// the best, it's solid gray?" The card is the app's one popover surface (`OverlaySurfaceView`,
/// themed Liquid Glass; vibrancy before macOS 26; the solid popup surface under Reduce
/// Transparency), its body paints no fill of its own, and it reads like Claude desktop's session
/// card: a clear title, muted metadata, then the last reply, truncated to two lines.
@MainActor @Suite(.serialized) struct WorkspaceHoverCardSurfaceTests {
    enum Look: String, CaseIterable { case light, dark, art }

    /// A light theme, a dark theme, and a see-through one over a work of art.
    private func scope(_ look: Look) throws -> ThemeScope {
        let scope = ThemeScope(level: .room)
        let input = switch look {
        case .light: ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x24292F))
        case .dark: ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4))
        case .art: ThemeInput(background: ThemeRGB(hex: 0x2B1650), foreground: ThemeRGB(hex: 0xF4E3FF), backgroundOpacity: 0.6)
        }
        scope.setOverride(try #require(ThemeSpec("Hover Card \(look.rawValue)")), input: input, animated: false)
        if look == .art { scope.pinBackdrop(.selection(.art(.vanGoghStarryNight))) }
        return scope
    }

    private static let content = WorkspaceHoverCardContent(
        title: "Make the session hover card match the popover surface", icon: .agentChat, age: "4m",
        facts: [
            .init(icon: .agentChat, text: "Codex · gpt-6.1-sol", kind: "agent"),
            .init(icon: .folder, text: "cmux", kind: "folder"),
            .init(icon: .agentChatList, text: "Done: the card is glass now, and the last reply reads under the metadata.",
                  lines: 2, kind: "lastReply"),
        ])

    /// The card in the hover card panel, as `HoverCardPanel.present` mounts it, drawing in `scope`.
    private func mounted(in scope: ThemeScope) -> (HoverCardPanel, WorkspaceHoverCardView) {
        let panel = HoverCardPanel()
        let body = WorkspaceHoverCardView()
        body.translatesAutoresizingMaskIntoConstraints = false
        panel.glass.contentView.addSubview(body)
        scope.adopt(panel)
        body.configure(Self.content)
        body.detailsToggle.performClick(nil)
        panel.themeDidChange()
        body.applyColors()
        return (panel, body)
    }

    @Test func theCardIsTheSharedOverlaySurfaceThatFollowsThisMac() {
        let panel = HoverCardPanel()
        #expect(panel.glass.materialOverride == nil)
        #expect(panel.glass.material == OverlayMaterial.select(liquidGlassAvailable: Glass.isLiquidGlassAvailable,
                                                              reduceTransparency: ReduceTransparency.shared.isEnabled))
        #expect(panel.glass.cornerRadius == HoverCardPanel.cornerRadius)
    }

    /// On each material the surface takes the scope's own tokens: the overlay glass tint (the
    /// theme's glass tint, `glassOverlayTintStrength` denser), or the popup surface when solid.
    @Test(arguments: Look.allCases)
    func theSurfaceTakesTheThemesOverlayTokens(look: Look) throws {
        let scope = try scope(look)
        let (panel, _) = mounted(in: scope)
        let strength = ChromeTunables.glassOverlayTintStrength.value
        let tint = scope.perform { Palette.glassTint }
        let overlayTint = tint.withAlphaComponent(min(max(tint.alphaComponent * strength, 0), 1))

        panel.glass.materialOverride = .liquidGlass
        let glass = try #require(panel.glass.subviews.compactMap { $0 as? GlassPanelView }.first)
        #expect(Self.same(try #require(glass.tintColor), overlayTint), "\(look)")

        panel.glass.materialOverride = .opaque
        let fill = try #require(panel.glass.subviews.first?.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
        #expect(Self.same(fill, scope.perform { Palette.popupSurface }), "\(look)")
        panel.glass.materialOverride = nil
    }

    /// Nothing in the card's body paints a fill (no fixed gray box over the glass): the surface
    /// under it is the only background.
    @Test(arguments: Look.allCases)
    func theBodyPaintsNoFillOverTheSurface(look: Look) throws {
        let (_, body) = mounted(in: try scope(look))
        var pending: [NSView] = [body]
        while let view = pending.popLast() {
            // A label's ink layer and the status indicator's glyph are not fills.
            if view.isHidden || view is ChromeLabel || view is StatusIndicatorView { continue }
            if let color = view.layer?.backgroundColor {
                #expect(color.alpha == 0, "\(look): \(type(of: view)) paints \(color)")
            }
            if let label = view as? NSTextField { #expect(!label.drawsBackground, "\(look)") }
            pending.append(contentsOf: view.subviews)
        }
    }

    /// The title and the last reply in the primary ink, the harness and folder muted, all the
    /// scope's own colors (no fixed gray).
    @Test(arguments: Look.allCases)
    func theTitleAndReplyLeadAndTheMetadataIsMuted(look: Look) throws {
        let scope = try scope(look)
        let (_, body) = mounted(in: scope)
        let primary = scope.perform { Palette.textPrimary }
        let secondary = scope.perform { Palette.textSecondary }
        let labels = Self.labels(in: body).filter { !$0.isHidden }
        func color(_ text: String) throws -> NSColor {
            try #require(labels.first { $0.stringValue == text }?.textColor, "\(look): no label \(text)")
        }
        #expect(Self.same(try color(Self.content.title), primary), "\(look)")
        #expect(Self.same(try color("Codex · gpt-6.1-sol"), secondary), "\(look)")
        #expect(Self.same(try color("cmux"), secondary), "\(look)")
        #expect(Self.same(try color(Self.content.facts[2].text), primary), "\(look)")
        let reply = try #require(labels.first { $0.stringValue == Self.content.facts[2].text })
        #expect(reply.maximumNumberOfLines == 2)
        #expect(reply.truncatesLastVisibleLine)
    }

    /// The last reply is the card's last line, under the metadata (the repository and branch, the
    /// machine): one place line, "cmux · fix/session-hover-card-glass" (Leo 2026-10-21).
    @Test func theLastReplyComesAfterTheMetadata() {
        var workspace = SidebarWorkspace(id: WorkspaceID("ws-chat"), title: "Make the card glass")
        workspace.agentName = "Codex"
        workspace.detail.model = "gpt-6.1-sol"
        workspace.lastMessage = "Done."
        workspace.directory = "~/code/cmux"
        workspace.branch = "fix/session-hover-card-glass"
        let kinds = WorkspaceHoverCardContent.make(workspace, machine: nil, now: Date()).facts.map(\.kind)
        #expect(kinds == ["agent", "branch", "lastReply"])
    }

    private static func same(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let lhs = lhs.usingColorSpace(.sRGB), let rhs = rhs.usingColorSpace(.sRGB) else { return false }
        return abs(lhs.redComponent - rhs.redComponent) < 0.01 && abs(lhs.greenComponent - rhs.greenComponent) < 0.01
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.01 && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.01
    }

    private static func labels(in view: NSView) -> [ChromeLabel] {
        var out: [ChromeLabel] = []
        var pending: [NSView] = [view]
        while let next = pending.popLast() {
            if let label = next as? ChromeLabel { out.append(label) }
            pending.append(contentsOf: next.subviews)
        }
        return out
    }
}
