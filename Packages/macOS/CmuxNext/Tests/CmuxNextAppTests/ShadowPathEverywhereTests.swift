import AppKit
@testable import CmuxNextAgentCursor
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextMacScreen
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import QuartzCore
import Testing

/// chrome-parity p03-rendering-108 (MQ-shadow-path): every layer that casts a shadow casts it from a
/// `shadowPath`, so Core Animation never renders it offscreen to find its alpha (Chrome draws shadows
/// from the shape, `ui/compositor_extra/shadow.cc`). Each surface below cast from its content before:
/// a lifted tab and group chip, the pane rings' glows, the agent cursor's dart, tag and caption, and
/// the switch knobs of the sidebar, Page Info and Mac Screen.
@MainActor @Suite(.serialized) struct ShadowPathEverywhereTests {
    /// Every layer in `root`'s tree that casts a shadow and has no path.
    static func contentShadows(in root: CALayer) -> [CALayer] {
        var found: [CALayer] = []
        func walk(_ layer: CALayer) {
            if layer.shadowOpacity > 0, layer.shadowPath == nil { found.append(layer) }
            for sublayer in layer.sublayers ?? [] { walk(sublayer) }
        }
        walk(root)
        return found
    }

    static func casting(in root: CALayer) -> [CALayer] {
        var found: [CALayer] = []
        func walk(_ layer: CALayer) {
            if layer.shadowOpacity > 0 { found.append(layer) }
            for sublayer in layer.sublayers ?? [] { walk(sublayer) }
        }
        walk(root)
        return found
    }

    @Test func aLiftedTabCastsFromItsPill() throws {
        let cell = TabCell(item: TabItem(id: TabID("t"), title: "cmux"))
        cell.frame = CGRect(x: 0, y: 0, width: 180, height: 32)
        cell.isLifted = true
        #expect(Self.contentShadows(in: cell.layer).isEmpty)
        let path = try #require(cell.backgroundLayer.shadowPath)
        #expect(path.boundingBoxOfPath.size == cell.backgroundLayer.bounds.size, "the shadow is not the pill's outline")
        cell.frame = CGRect(x: 0, y: 0, width: 120, height: 32)
        #expect(cell.backgroundLayer.shadowPath?.boundingBoxOfPath.size == cell.backgroundLayer.bounds.size,
                "a resize left the old outline")
    }

    @Test func aLiftedGroupChipCastsFromItsPill() throws {
        let chip = TabGroupChipCell(group: TabGroupItem(id: "g", name: "Frontend"), memberCount: 3)
        chip.frame = CGRect(x: 0, y: 0, width: chip.slotWidth, height: 32)
        chip.isLifted = true
        #expect(Self.contentShadows(in: chip.layer).isEmpty)
        #expect(chip.pill.shadowPath?.boundingBoxOfPath.size == chip.pill.bounds.size)
    }

    @Test func thePaneGlowsCastFromTheirBorders() throws {
        let design = DesignSettings.shared
        let saved = design.attention
        defer { design.attention = saved }
        var settings = AttentionSettings()
        settings.terminalRing = .glow
        design.attention = settings
        let view = PaneOverlayView()
        view.setFrameSize(NSSize(width: 400, height: 300))
        view.setShape(padding: 6, cornerRadius: 10, headerHeight: 0)
        var focusRing = FocusRingSettings()
        focusRing.style = .glow
        view.update(showsRing: true, dim: 0, focusRing: focusRing, border: PaneOverlayView.Border(shows: false),
                    attention: AttentionMark(generation: 1, quiet: true), attentionSettings: settings, animated: false)
        let layer = try #require(view.layer)
        #expect(!Self.casting(in: layer).isEmpty, "nothing glows")
        #expect(Self.contentShadows(in: layer).isEmpty)
        let glow = view.glowLayer
        let band = try #require(glow.shadowPath)
        let inside = CGPoint(x: glow.bounds.midX, y: glow.bounds.midY)
        #expect(!band.contains(inside), "the focus glow casts from inside its ring")
    }

    @Test func theAgentCursorCastsFromItsShapes() throws {
        let cursor = AgentCursorLayer(color: AgentCursorLayer.gray, name: "Claude · cmux", scale: 2)
        cursor.showCaption("ls -la", scale: 2)
        #expect(!Self.casting(in: cursor.root).isEmpty, "nothing casts")
        #expect(Self.contentShadows(in: cursor.root).isEmpty)
        #expect(cursor.nameTag.shadowPath?.boundingBoxOfPath.size == cursor.nameTag.bounds.size)
        #expect(cursor.caption.shadowPath?.boundingBoxOfPath.size == cursor.caption.bounds.size)
    }

    @Test func switchKnobsCastFromTheirOutlines() throws {
        let sidebar = SidebarUpdateToggle(frame: CGRect(x: 0, y: 0, width: 200, height: 24))
        sidebar.fixedLook = .switchControl
        sidebar.layout()
        sidebar.updateLayer()
        let pageInfo = PageInfoToggle(frame: CGRect(origin: .zero, size: PageInfoStyle.toggleSize))
        pageInfo.layout()
        let macScreen = MacScreenSwitch(id: "s", label: "Share")
        macScreen.layout()
        for view in [sidebar, pageInfo, macScreen] as [NSView] {
            let layer = try #require(view.layer)
            #expect(!Self.casting(in: layer).isEmpty, "\(type(of: view)): nothing casts")
            #expect(Self.contentShadows(in: layer).isEmpty, "\(type(of: view)) casts from its content")
        }
    }
}
