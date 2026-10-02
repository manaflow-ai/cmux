import AppKit
import Testing
@testable import CmuxNextDesign

/// The sidebar's and tab strips' tonal step: one translucent theme color
/// from the view's scope, the same whether the window is opaque or
/// see-through, with no material of its own (the window root owns the only
/// one), and never in the way of a click. The view does not read Reduce
/// Transparency: the root decides the material, so no host setting reaches
/// these tests.
@MainActor @Suite(.serialized) struct ChromeStepViewTests {
    private func step(in input: ThemeInput, named name: String,
                      _ color: @escaping @MainActor () -> NSColor = { Palette.sidebarStep }) -> (ChromeStepView, ThemeScope) {
        let room = ThemeScope(level: .room)
        room.setOverride(ThemeSpec(name)!, input: input, animated: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        room.root(host)
        let view = ChromeStepView(step: color)
        view.frame = host.bounds
        host.addSubview(view)
        view.viewDidChangeEffectiveAppearance()
        return (view, room)
    }

    private func expectColor(_ view: ChromeStepView, _ expected: ThemeRGB) throws {
        let color = try #require(view.stepColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
        #expect(abs(color.redComponent - expected.red) < 0.01)
        #expect(abs(color.greenComponent - expected.green) < 0.01)
        #expect(abs(color.blueComponent - expected.blue) < 0.01)
        #expect(abs(color.alphaComponent - expected.alpha) < 0.01)
    }

    /// Opaque and see-through windows get the same step and no material
    /// view: a translucent window's blur is the root's alone.
    @Test(arguments: [1.0, 0.85])
    func paintsOnlyTheStepAtAnyOpacity(opacity: Double) throws {
        var input = ThemeFixtures.catppuccinMocha
        input.backgroundOpacity = opacity
        let (view, _) = step(in: input, named: "Catppuccin Mocha")
        #expect(view.subviews.isEmpty)
        try expectColor(view, ThemeTokens.derive(from: input).sidebarStep)
    }

    /// The strip's step comes from the strip token.
    @Test func theStripPaintsTheStripStep() throws {
        let (view, _) = step(in: ThemeFixtures.gruvboxDark, named: "Gruvbox Dark") { Palette.stripStep }
        try expectColor(view, ThemeTokens.derive(from: ThemeFixtures.gruvboxDark).stripStep)
    }

    /// A theme change reaches the chrome without a relaunch.
    @Test func aThemeChangeUpdatesTheStep() throws {
        let (view, room) = step(in: ThemeFixtures.catppuccinMocha, named: "Catppuccin Mocha")
        room.setOverride(ThemeSpec("GitHub Light")!, input: ThemeFixtures.githubLight, animated: false)
        view.viewDidChangeEffectiveAppearance()
        try expectColor(view, ThemeTokens.derive(from: ThemeFixtures.githubLight).sidebarStep)
    }

    @Test func clicksPassThrough() {
        let view = ChromeStepView { Palette.stripStep }
        view.frame = NSRect(x: 0, y: 0, width: 100, height: 40)
        #expect(view.hitTest(NSPoint(x: 10, y: 10)) == nil)
    }
}
