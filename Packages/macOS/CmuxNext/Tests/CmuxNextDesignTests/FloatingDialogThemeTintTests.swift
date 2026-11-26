import AppKit
import CmuxNextTestSupport
import CmuxTheme
@testable import CmuxNextDesign
import Testing

/// Leo 2026-11-22, on the "A machine on your team asked to control this Mac." card at the top right: "im not sure what
/// was up with the glass on it, and the lack of theming on it too". Every card in the floating dialog panel floats over
/// other apps, so it draws theme-tinted glass: the transient glass, whose veil is the theme's glass tint, as toasts do,
/// or with Settings > Experiments > Themed Floating Prompts on (off by default), the ``SurfaceRole/prompt`` glass
/// (``FloatingPromptGlassTests``); its veil is the theme's tint too
/// (``ToastVeilThemeTintTests``). The sheet glass it drew before has a gray veil that the shipped Liquid Glass variant
/// drops, so the device-control prompts showed bare, untinted glass in every theme, while Add Server, Pair Invite and Add
/// Machine, which opted into the transient glass one by one, were themed.
@MainActor @Suite(.serialized, .closesItsWindows)
struct FloatingDialogThemeTintTests {
    private static let spec = CmuxDialogSpec(
        title: "A machine on your team asked to control this Mac.",
        lines: ["Allow control from your team's machines?", "You can change this later in Settings > Devices."],
        buttons: [CmuxDialogButton(id: "deny", title: "Deny", role: .cancel),
                  CmuxDialogButton(id: "allow", title: "Allow", role: .default, personOnly: true)],
        identifier: "test.floatingDialog")

    /// The colour the surface lays over its glass (``ToastVeilThemeTintTests``' reading).
    private static func paintedVeil(_ surface: OverlaySurfaceView) -> NSColor? {
        var stack = surface.subviews
        while let view = stack.popLast() {
            if view === surface.contentView || view.isDescendant(of: surface.contentView) || view is GlassRimView { continue }
            if let glass = view as? GlassPanelView, let tint = glass.tintColor { return tint.usingColorSpace(.sRGB) }
            if let fill = view.layer?.backgroundColor, let color = NSColor(cgColor: fill), color.alphaComponent > 0 {
                return color.usingColorSpace(.sRGB)
            }
            stack += view.subviews
        }
        return nil
    }

    /// Off (the default) the floating cards draw the transient glass, as before; on, the prompt glass: the theme's
    /// tint at a denser veil (``FloatingPromptGlassTests``).
    @Test(arguments: [false, true])
    func aFloatingPanelsCardDrawsThemedGlass(themedPrompts: Bool) throws {
        try DesignSettings.$themedPromptsOverride.withValue(themedPrompts) {
            let panel = CmuxFloatingDialogPanel(identifier: "test.floatingDialog.panel")
            defer { panel.hide(); panel.close() }
            #expect(!Self.spec.usesTransientMaterial, "the spec itself does not ask for it: the panel does")
            let card = panel.show(Self.spec) { _ in }
            #expect(card.dialog.floatsOverApps)
            #expect(card.overApps == themedPrompts)
            let surface = try #require(card.surface)
            #expect(surface.glass.tone.style == (themedPrompts ? .prompt : .transient))
        }
    }

    @Test(arguments: [false, true])
    func aHostViewsCardDrawsThemedGlass(themedPrompts: Bool) throws {
        try DesignSettings.$themedPromptsOverride.withValue(themedPrompts) {
            let host = CmuxDialogHostView(frame: NSRect(x: 0, y: 0, width: 432, height: 160))
            let card = host.draw(Self.spec) { _ in }
            #expect(card.dialog.floatsOverApps)
            let surface = try #require(card.surface)
            #expect(surface.glass.tone.style == (themedPrompts ? .prompt : .transient))
        }
    }

    /// The switch is off by default: with no override, nothing turned it on.
    @Test func themedPromptsIsOffByDefault() {
        #expect(DesignSettings.themedPromptsOverride == nil)
        #expect(DesignSettings().themedPrompts == false)
    }

    @Test func anInAppStandaloneCardKeepsTheSheetGlass() throws {
        let card = CmuxDialogView(dialog: .standalone(Self.spec, onPress: { _ in }))
        #expect(!card.dialog.floatsOverApps)
        #expect(try #require(card.surface).glass.tone.style == .dialog)
    }

    @Test func theFloatingCardsVeilTakesTheThemesTint() throws {
        let theme = try #require(try CardNeverOpaqueTests.bundledThemes().first { $0.name == "Hot Dog Stand" })
        let scope = ThemeScope(level: .room)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = try #require(window.contentView)
        scope.root(root)
        let card = CmuxDialogView(dialog: .standalone(Self.spec, floatsOverApps: true, onPress: { _ in }))
        card.frame = NSRect(x: 20, y: 20, width: 432, height: 160)
        root.addSubview(card)
        scope.setOverride(try #require(ThemeSpec("Glass \(theme.name)")), input: theme.input, animated: false)
        root.layoutSubtreeIfNeeded()
        let surface = try #require(card.surface).glass
        // The glass path, not Reduce Transparency's opaque one, which this Mac may have on.
        guard surface.material != .opaque else { return }
        let painted = try #require(Self.paintedVeil(surface))
        let wanted = Palette.veilRGB(of: .transient, tokens: scope.tokens)
        let channels: [(Double, Double)] = [(Double(painted.redComponent), wanted.red), (Double(painted.greenComponent), wanted.green),
                                            (Double(painted.blueComponent), wanted.blue)]
        for (shown, expected) in channels { #expect(abs(shown - expected) < 0.02, "veil \(painted), wanted \(wanted)") }
        let hue = Double(painted.redComponent) - Double(painted.blueComponent)
        #expect(hue > 0.2, "the floating card's veil carries the theme's red, not bare glass: \(painted)")
    }
}
