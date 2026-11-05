import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// The workspace hover card names its machine once, in its header (Leo 2026-11-02: "the tiny cloud icon the
/// repeated cloud cloud cloud"). The name keeps today's quiet ink (textSecondary) until the person picks a color
/// for that machine (`appearance.machineColors`); then it draws the pick. The connection dot keeps its own tone.
/// Read from the card as drawn.
@MainActor @Suite(.serialized) struct HoverCardMachineColorTests {
    /// The header's machine name color, textSecondary in the card's theme scope (sRGB), and the card.
    static func machineName(picks: MachineColorOverrides) throws -> (name: NSColor, secondary: NSColor, card: WorkspaceHoverCardView) {
        ThemeScope.app.store.setMachineColors(picks)
        defer { ThemeScope.app.store.setMachineColors(.none) }
        let machine = SidebarMachine(id: CmuxNextSidebar.MachineID("my-vm"), name: "my-vm", kind: .ssh, status: .connected)
        var workspace = SidebarWorkspace(id: CmuxNextSidebar.WorkspaceID("ws-remote"), machineID: machine.id, title: "Deploy")
        workspace.directory = "~/code"
        let card = WorkspaceHoverCardView()
        card.configure(.make(workspace, machine: machine, now: Date()))
        try #require(card.hostLabel.stringValue == "my-vm" && !card.hostLabel.isHidden)
        let name = try #require(card.hostLabel.textColor?.usingColorSpace(.sRGB))
        let secondary = try #require(card.performWithTheme { Palette.textSecondary }.usingColorSpace(.sRGB))
        return (name, secondary, card)
    }

    static func same(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        abs(lhs.redComponent - rhs.redComponent) < 0.01 && abs(lhs.greenComponent - rhs.greenComponent) < 0.01
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.01 && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.01
    }

    @Test func withNoPickTheNameStaysSecondary() throws {
        let (name, secondary, card) = try Self.machineName(picks: .none)
        #expect(Self.same(name, secondary), "name \(name), textSecondary \(secondary)")
        #expect(card.lines.filter { $0.contains("my-vm") }.count == 1, "\(card.lines)")
    }

    @Test func aPickForAnotherMachineLeavesItSecondary() throws {
        let (name, secondary, _) = try Self.machineName(picks: MachineColorOverrides(["build-mac": "#12ab34"]))
        #expect(Self.same(name, secondary), "name \(name), textSecondary \(secondary)")
    }

    @Test func withAPickTheNameDrawsIt() throws {
        let (name, _, _) = try Self.machineName(picks: MachineColorOverrides(["My-VM": "#12ab34"]))
        let picked = try #require(ThemeRGB(cssHex: "#12ab34")?.nsColor.usingColorSpace(.sRGB))
        #expect(Self.same(name, picked), "name \(name), pick \(picked)")
    }

    /// A pick made while the card is open reaches the name: the store's repaint runs each view's appearance hook.
    @Test func aPickWhileTheCardIsOpenRecolorsTheName() throws {
        let (_, secondary, card) = try Self.machineName(picks: .none)
        ThemeScope.app.store.setMachineColors(MachineColorOverrides(["my-vm": "#12ab34"]))
        defer { ThemeScope.app.store.setMachineColors(.none) }
        card.viewDidChangeEffectiveAppearance()
        let name = try #require(card.hostLabel.textColor?.usingColorSpace(.sRGB))
        let picked = try #require(ThemeRGB(cssHex: "#12ab34")?.nsColor.usingColorSpace(.sRGB))
        #expect(Self.same(name, picked), "name \(name), pick \(picked)")
        ThemeScope.app.store.setMachineColors(.none)
        card.viewDidChangeEffectiveAppearance()
        let reset = try #require(card.hostLabel.textColor?.usingColorSpace(.sRGB))
        #expect(Self.same(reset, secondary), "name \(reset), textSecondary \(secondary)")
    }
}
