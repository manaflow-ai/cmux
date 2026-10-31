import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// The workspace hover card's machine row keeps today's quiet icon (textSecondary) until the
/// person picks a color for that machine (`appearance.machineColors`); then the icon draws the
/// pick. The connection dot keeps its own tone. Read from the card as drawn.
@MainActor @Suite(.serialized) struct HoverCardMachineColorTests {
    /// The machine row's icon tint, its dot, and textSecondary in the row's theme scope, sRGB.
    static func machineRow(picks: MachineColorOverrides) throws -> (icon: NSColor, secondary: NSColor, row: HoverCardRowView) {
        ThemeScope.app.store.setMachineColors(picks)
        defer { ThemeScope.app.store.setMachineColors(.none) }
        let machine = SidebarMachine(id: CmuxNextSidebar.MachineID("big-red"), name: "big-red", kind: .ssh, status: .connected)
        var workspace = SidebarWorkspace(id: CmuxNextSidebar.WorkspaceID("ws-remote"), machineID: machine.id, title: "Deploy")
        workspace.directory = "~/code"
        let card = WorkspaceHoverCardView()
        card.configure(.make(workspace, machine: machine, now: Date()))
        card.detailsToggle.performClick(nil)
        let row = try #require(rows(in: card).first { !$0.isHidden && $0.textLabel.stringValue == "big-red" })
        let icon = try #require(row.icon.contentTintColor?.usingColorSpace(.sRGB))
        let secondary = try #require(row.performWithTheme { Palette.textSecondary }.usingColorSpace(.sRGB))
        return (icon, secondary, row)
    }

    private static func rows(in view: NSView) -> [HoverCardRowView] {
        var out: [HoverCardRowView] = []
        var pending: [NSView] = [view]
        while let next = pending.popLast() {
            if let row = next as? HoverCardRowView { out.append(row) }
            pending.append(contentsOf: next.subviews)
        }
        return out
    }

    static func same(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        abs(lhs.redComponent - rhs.redComponent) < 0.01 && abs(lhs.greenComponent - rhs.greenComponent) < 0.01
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.01 && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.01
    }

    @Test func withNoPickTheIconStaysSecondary() throws {
        let (icon, secondary, row) = try Self.machineRow(picks: .none)
        #expect(Self.same(icon, secondary), "icon \(icon), textSecondary \(secondary)")
        #expect(row.content.accessory == .dot(.success))
    }

    @Test func aPickForAnotherMachineLeavesItSecondary() throws {
        let (icon, secondary, _) = try Self.machineRow(picks: MachineColorOverrides(["build-mac": "#12ab34"]))
        #expect(Self.same(icon, secondary), "icon \(icon), textSecondary \(secondary)")
    }

    @Test func withAPickTheIconDrawsItAndTheDotKeepsItsTone() throws {
        let (icon, _, row) = try Self.machineRow(picks: MachineColorOverrides(["Big-Red": "#12ab34"]))
        let picked = try #require(ThemeRGB(cssHex: "#12ab34")?.nsColor.usingColorSpace(.sRGB))
        #expect(Self.same(icon, picked), "icon \(icon), pick \(picked)")
        #expect(row.content.accessory == .dot(.success))
    }

    /// A pick made while the card is open reaches its icon: the store's repaint runs each view's
    /// appearance hook, and the row recolors in it.
    @Test func aPickWhileTheCardIsOpenRecolorsTheIcon() throws {
        let (_, secondary, row) = try Self.machineRow(picks: .none)
        ThemeScope.app.store.setMachineColors(MachineColorOverrides(["big-red": "#12ab34"]))
        defer { ThemeScope.app.store.setMachineColors(.none) }
        row.viewDidChangeEffectiveAppearance()
        let icon = try #require(row.icon.contentTintColor?.usingColorSpace(.sRGB))
        let picked = try #require(ThemeRGB(cssHex: "#12ab34")?.nsColor.usingColorSpace(.sRGB))
        #expect(Self.same(icon, picked), "icon \(icon), pick \(picked)")
        ThemeScope.app.store.setMachineColors(.none)
        row.viewDidChangeEffectiveAppearance()
        let reset = try #require(row.icon.contentTintColor?.usingColorSpace(.sRGB))
        #expect(Self.same(reset, secondary), "icon \(reset), textSecondary \(secondary)")
    }
}
