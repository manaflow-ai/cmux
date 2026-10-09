import AppKit
import Testing
@testable import CmuxNextDesign

/// Room, workspace and terminal themes (plans/cmux-next/data-model.md 6):
/// precedence, fallbacks, and what each view resolves.
@MainActor @Suite(.serialized) struct ThemeScopeTests {
    final class Recorder: ThemeResponsive {
        var calls = 0
        func themeDidChange() { calls += 1 }
    }

    /// Resolves its background the way every chrome view does.
    final class ProbeView: NSView {
        var resolved: CGColor?
        var appearanceCalls = 0
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            appearanceCalls += 1
            performWithTheme { resolved = Palette.contentBackground.cgColor }
        }
    }

    private func background(_ input: ThemeInput) -> CGColor {
        ThemeTokens.derive(from: input).contentBackground.cgColor
    }

    private func spec(_ name: String) -> ThemeSpec { ThemeSpec(name)! }

    @Test func scopesInheritUntilTheyOverride() {
        let room = ThemeScope(level: .room)
        let workspace = ThemeScope(level: .workspace, parent: room)
        let terminal = ThemeScope(level: .terminal, parent: workspace)
        #expect(terminal.tokens == ThemeScope.app.tokens)
        #expect(terminal.source == .config)

        room.setOverride(spec("Gruvbox Dark"), input: ThemeFixtures.gruvboxDark, animated: false)
        #expect(workspace.tokens == ThemeTokens.derive(from: ThemeFixtures.gruvboxDark))
        #expect(terminal.tokens == workspace.tokens)
        #expect(terminal.source == .room)
        #expect(terminal.effectiveSpec?.raw == "Gruvbox Dark")

        workspace.setOverride(spec("GitHub Light Default"), input: ThemeFixtures.githubLight, animated: false)
        #expect(room.tokens == ThemeTokens.derive(from: ThemeFixtures.gruvboxDark))
        #expect(terminal.tokens == ThemeTokens.derive(from: ThemeFixtures.githubLight))
        #expect(terminal.source == .workspace)

        terminal.setOverride(spec("Catppuccin Mocha"), input: ThemeFixtures.catppuccinMocha, animated: false)
        #expect(terminal.tokens == ThemeTokens.derive(from: ThemeFixtures.catppuccinMocha))
        #expect(workspace.tokens == ThemeTokens.derive(from: ThemeFixtures.githubLight))

        // Clearing falls back one level at a time.
        terminal.setOverride(nil, input: nil, animated: false)
        #expect(terminal.tokens == workspace.tokens)
        workspace.setOverride(nil, input: nil, animated: false)
        #expect(terminal.tokens == room.tokens)
        room.setOverride(nil, input: nil, animated: false)
        #expect(terminal.tokens == ThemeScope.app.tokens)
        #expect(terminal.effectiveSpec == nil)
    }

    @Test func aSpecWithoutColorsDoesNotOverride() {
        let room = ThemeScope(level: .room)
        room.setOverride(spec("Missing Theme"), input: nil, animated: false)
        #expect(room.spec == nil)
        #expect(room.tokens == ThemeScope.app.tokens)
    }

    @Test func respondersHearOnlyRealChanges() {
        let room = ThemeScope(level: .room)
        let workspace = ThemeScope(level: .workspace, parent: room)
        let recorder = Recorder()
        workspace.addResponder(recorder)
        room.setOverride(spec("Nord"), input: ThemeFixtures.gruvboxDark, animated: false)
        #expect(recorder.calls == 1)
        #expect(workspace.generation == 1)
        room.setOverride(spec("Nord"), input: ThemeFixtures.gruvboxDark, animated: false)
        #expect(recorder.calls == 1)
        // An overridden child ignores its parent's changes.
        workspace.setOverride(spec("Latte"), input: ThemeFixtures.githubLight, animated: false)
        room.setOverride(spec("Mocha"), input: ThemeFixtures.catppuccinMocha, animated: false)
        #expect(recorder.calls == 2)
    }

    @Test func movingAScopeInheritsFromItsNewParent() {
        let first = ThemeScope(level: .room)
        let second = ThemeScope(level: .room)
        first.setOverride(spec("A"), input: ThemeFixtures.gruvboxDark, animated: false)
        second.setOverride(spec("B"), input: ThemeFixtures.githubLight, animated: false)
        let workspace = ThemeScope(level: .workspace, parent: first)
        #expect(workspace.tokens == first.tokens)
        workspace.setParent(second)
        #expect(workspace.tokens == second.tokens)
    }

    @Test func viewsResolveTheNearestScope() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let room = ThemeScope(level: .room)
        room.setOverride(spec("Gruvbox Dark"), input: ThemeFixtures.gruvboxDark, animated: false)
        let chrome = ProbeView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let pane = ProbeView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        window.contentView.addSubview(chrome)
        window.contentView.addSubview(content)
        content.addSubview(pane)
        room.adopt(window)
        let workspace = ThemeScope(level: .workspace, parent: room)
        workspace.setOverride(spec("Catppuccin Mocha"), input: ThemeFixtures.catppuccinMocha, animated: false)
        workspace.root(content)

        #expect(chrome.themeScope === room)
        #expect(pane.themeScope === workspace)
        #expect(chrome.resolved == background(ThemeFixtures.gruvboxDark))
        #expect(pane.resolved == background(ThemeFixtures.catppuccinMocha))

        // A panel owned by the window draws in the window's scope.
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 50, height: 50), styleMask: [.borderless], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.adoptThemeScope(of: chrome)
        #expect(panel.contentView.themeScope === room)
        #expect(panel.appearance?.name == .darkAqua)

        // Unrooting returns the subtree to the window's scope.
        workspace.unroot(content)
        #expect(pane.themeScope === room)
        #expect(pane.resolved == background(ThemeFixtures.gruvboxDark))

        // A detached view draws in the app theme.
        #expect(NSView().themeScope === ThemeScope.app)
    }

    @Test func aThemeChangeRepaintsOnlyThatScope() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let room = ThemeScope(level: .room)
        room.adopt(window)
        let chrome = ProbeView(frame: .zero)
        let content = NSView(frame: .zero)
        let pane = ProbeView(frame: .zero)
        window.contentView.addSubview(chrome)
        window.contentView.addSubview(content)
        content.addSubview(pane)
        let workspace = ThemeScope(level: .workspace, parent: room)
        workspace.root(content)
        let chromeCalls = chrome.appearanceCalls

        workspace.setOverride(spec("Gruvbox Dark"), input: ThemeFixtures.gruvboxDark, animated: false)
        #expect(chrome.appearanceCalls == chromeCalls)
        #expect(pane.resolved == background(ThemeFixtures.gruvboxDark))

        room.setOverride(spec("Latte"), input: ThemeFixtures.githubLight, animated: false)
        #expect(chrome.appearanceCalls > chromeCalls)
        #expect(chrome.resolved == background(ThemeFixtures.githubLight))
        #expect(window.appearance?.name == .aqua)
        // The workspace keeps its own dark theme and says so to AppKit.
        #expect(pane.resolved == background(ThemeFixtures.gruvboxDark))
        #expect(content.appearance?.name == .darkAqua)
    }

    /// A workspace theme recolored only the content, so the sidebar and
    /// titlebar kept the room theme beside it (Monokai next to Catppuccin).
    /// The window's chrome draws in the shown workspace's colors while they
    /// are as dark (or light) as the room's; a light workspace in a dark room
    /// leaves the chrome dark. Other workspaces keep inheriting the room.
    @Test func chromeDrawsInTheShownWorkspacesColorsOfTheSameMode() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let room = ThemeScope(level: .room)
        room.setOverride(spec("Gruvbox Dark"), input: ThemeFixtures.gruvboxDark, animated: false)
        room.adopt(window)
        let sidebar = ProbeView(frame: .zero)
        let content = NSView(frame: .zero)
        let pane = ProbeView(frame: .zero)
        window.contentView.addSubview(sidebar)
        window.contentView.addSubview(content)
        content.addSubview(pane)
        let shown = ThemeScope(level: .workspace, parent: room)
        let parked = ThemeScope(level: .workspace, parent: room)
        shown.setOverride(spec("Catppuccin Mocha"), input: ThemeFixtures.catppuccinMocha, animated: false)
        shown.root(content)
        let recorder = Recorder()
        room.addResponder(recorder)

        room.show(shown)
        #expect(sidebar.resolved == background(ThemeFixtures.catppuccinMocha))
        #expect(sidebar.resolved == pane.resolved)
        #expect(window.appearance?.name == .darkAqua)
        #expect(content.appearance == nil)
        #expect(recorder.calls == 1)
        // Children inherit the room's own theme, not the shown one.
        #expect(room.ownTokens == ThemeTokens.derive(from: ThemeFixtures.gruvboxDark))
        #expect(parked.tokens == room.ownTokens)
        let terminal = ThemeScope(level: .terminal, parent: room)
        #expect(terminal.tokens == room.ownTokens)

        // A light theme on the shown workspace leaves the dark chrome alone.
        shown.setOverride(spec("GitHub Light Default"), input: ThemeFixtures.githubLight, animated: false)
        #expect(sidebar.resolved == background(ThemeFixtures.gruvboxDark))
        #expect(window.appearance?.name == .darkAqua)
        #expect(content.appearance?.name == .aqua)
        #expect(pane.resolved == background(ThemeFixtures.githubLight))
        #expect(recorder.calls == 2)

        // A light room follows the light workspace again.
        room.setOverride(spec("Latte"), input: ThemeFixtures.githubLight, animated: false)
        #expect(sidebar.resolved == background(ThemeFixtures.githubLight))
        #expect(window.appearance?.name == .aqua)
        #expect(parked.tokens == ThemeTokens.derive(from: ThemeFixtures.githubLight))
        #expect(recorder.calls == 3)

        // Showing a workspace without its own theme draws in the room's.
        room.show(parked)
        #expect(sidebar.resolved == background(ThemeFixtures.githubLight))
        #expect(recorder.calls == 3)
        room.show(nil)
        #expect(room.tokens == room.ownTokens)
    }

    @Test func paletteOutsideAScopeIsTheAppTheme() {
        let room = ThemeScope(level: .room)
        room.setOverride(spec("Gruvbox Dark"), input: ThemeFixtures.gruvboxDark, animated: false)
        let scoped = room.perform { Palette.textPrimary.cgColor }
        #expect(scoped == ThemeTokens.derive(from: ThemeFixtures.gruvboxDark).textPrimary.cgColor)
        var unscoped: CGColor?
        ThemeScope.app.appearance.performAsCurrentDrawingAppearance { unscoped = Palette.textPrimary.cgColor }
        #expect(unscoped == ThemeSnapshot.tokens.textPrimary.cgColor)
    }
}
