import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// The workspace hover card names its machine once, in its header (Leo 2026-11-02: "the tiny cloud icon the
/// repeated cloud cloud cloud"). The name keeps today's quiet ink (textSecondary) until the person picks a color
/// for that machine (`appearance.machineColors`); then it draws the pick, fitted to read on the card: its hue, raised
/// to 4.5:1 on the overlay card (`MachineColor.pickedCardTextColor`, 3cd55d9ca42: "every single theme, all the UI
/// elements are colored properly"). The connection dot keeps its own tone. Read from the card as drawn.
@MainActor @Suite(.serialized) struct HoverCardMachineColorTests {
    /// The header's machine name color, textSecondary in the card's theme scope (sRGB), and the card.
    static func machineName(picks: MachineColorOverrides) throws -> (name: NSColor, secondary: NSColor, card: WorkspaceHoverCardView) {
        try machineNameAndPick(picks: picks).drawn
    }

    /// As ``machineName(picks:)``, with the pick as card text in the card's theme scope (nil without a pick for my-vm).
    static func machineNameAndPick(picks: MachineColorOverrides) throws
        -> (drawn: (name: NSColor, secondary: NSColor, card: WorkspaceHoverCardView), pick: NSColor?) {
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
        return ((name, secondary, card), cardText(card))
    }

    /// my-vm's pick as text on `card` (its hue, fitted to read on the overlay card), in the card's theme scope.
    static func cardText(_ card: WorkspaceHoverCardView) -> NSColor? {
        card.performWithTheme { MachineColor(name: "my-vm").pickedCardTextColor }?.usingColorSpace(.sRGB)
    }

    /// The pick drawn as text: the fitted color, the pick's hue, never the quiet ink.
    static func drawsThePick(_ name: NSColor, fitted: NSColor, picked: NSColor, secondary: NSColor) {
        #expect(same(name, fitted), "name \(name), pick as card text \(fitted)")
        #expect(abs(name.hueComponent - picked.hueComponent) < 0.02, "name \(name) left the pick's hue \(picked)")
        #expect(!same(name, secondary), "name \(name) is the quiet ink")
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
        let (drawn, pick) = try Self.machineNameAndPick(picks: MachineColorOverrides(["My-VM": "#12ab34"]))
        let fitted = try #require(pick, "my-vm's pick is not read case-blind")
        let picked = try #require(ThemeRGB(cssHex: "#12ab34")?.nsColor.usingColorSpace(.sRGB))
        Self.drawsThePick(drawn.name, fitted: fitted, picked: picked, secondary: drawn.secondary)
    }

    /// A pick made while the card is open reaches the name: the store's repaint runs each view's appearance hook.
    @Test func aPickWhileTheCardIsOpenRecolorsTheName() throws {
        let (_, secondary, card) = try Self.machineName(picks: .none)
        ThemeScope.app.store.setMachineColors(MachineColorOverrides(["my-vm": "#12ab34"]))
        defer { ThemeScope.app.store.setMachineColors(.none) }
        card.viewDidChangeEffectiveAppearance()
        let name = try #require(card.hostLabel.textColor?.usingColorSpace(.sRGB))
        let fitted = try #require(Self.cardText(card))
        let picked = try #require(ThemeRGB(cssHex: "#12ab34")?.nsColor.usingColorSpace(.sRGB))
        Self.drawsThePick(name, fitted: fitted, picked: picked, secondary: secondary)
        ThemeScope.app.store.setMachineColors(.none)
        card.viewDidChangeEffectiveAppearance()
        let reset = try #require(card.hostLabel.textColor?.usingColorSpace(.sRGB))
        #expect(Self.same(reset, secondary), "name \(reset), textSecondary \(secondary)")
    }
}
