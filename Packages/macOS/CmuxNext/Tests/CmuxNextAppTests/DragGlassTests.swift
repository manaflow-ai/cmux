import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import Testing

/// Leo, 2026-10-19: "the dragged workspaces and dragged tabs turning from glassy to solid themed is
/// so shitty". In a translucent window a picked-up tab and the drag ghost are glass over the
/// window's art and tint (`WindowBackdrop.dragsOnGlass`), not a flat theme card; a lifted sidebar row
/// is the overlay glass (`DragLiftView`) and its ghost keeps it; a window opened for a torn-off
/// workspace or tab gets the same backdrop as the window it left.
@MainActor @Suite(.serialized) struct DragGlassTests {
    /// Runs `body` with the app theme translucent and frosted, as cmux.json's
    /// `appearance.backgroundOpacity` 0.65 and `backgroundBlur` "frosted" make it.
    func translucent<T>(_ body: () throws -> T) rethrows -> T {
        let original = ThemeScope.app.store.input
        defer { _ = ThemeScope.app.store.apply(original) }
        var input = original
        input.backgroundOpacity = 0.65
        input.backgroundBlur = 20
        _ = ThemeScope.app.store.apply(input)
        return try body()
    }

    static var reducesTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }

    @Test func liftAndCardFillsAreGlassOnlyInATranslucentWindow() {
        var input = ThemeInput.ghosttyDefault
        input.backgroundOpacity = 0.65
        let glass = WindowBackdrop(ThemeTokens.derive(from: input))
        let opaque = WindowBackdrop(ThemeTokens.derive(from: .ghosttyDefault))
        #expect(glass.dragsOnGlass)
        #expect(!opaque.dragsOnGlass)
        let lift = glass.dragLiftFill(.red).alphaComponent
        #expect(lift > CGFloat(glass.tintOpacity) && lift < 1, "a thicker piece of the window's glass, never solid")
        #expect(lift == glass.dragLiftAlpha)
        #expect(opaque.dragLiftFill(.red).alphaComponent == 1)
        #expect(glass.dragCardFill(.red) == nil, "the ghost's glass is the card")
        #expect(opaque.dragCardFill(.red)?.alphaComponent == 1)
    }

    /// The lifted row is the overlay glass in every window (u5506) but under Reduce Transparency;
    /// its snapshot does not draw the glass, so the handoff tells the ghost to.
    @Test func aLiftedSidebarRowHandsItsGlassToTheGhost() {
        #expect(DragLiftView(content: NSView(), count: 1, material: .liquidGlass).isGlass)
        #expect(DragLiftView(content: NSView(), count: 1, material: .vibrancy).isGlass)
        #expect(!DragLiftView(content: NSView(), count: 1, material: .opaque).isGlass)
    }

    @Test func aLiftedTabLetsTheWindowsGlassReadThrough() throws {
        try translucent {
            let cell = TabCell(item: TabItem(id: TabID("t"), title: "New Tab"))
            cell.isLifted = true
            let fill = try #require(cell.backgroundLayer.backgroundColor)
            if Self.reducesTransparency { #expect(fill.alpha == 1) } else { #expect(fill.alpha < 1) }
        }
    }

    @Test func theDragGhostStandsOnGlassFromItsFirstFrame() throws {
        let ghost = TabDragGhostPanel(tabImage: nil, tabSize: CGSize(width: 160, height: 28),
                                      grabOffset: CGPoint(x: 20, y: 14), aspect: 1.6, scale: 2, onGlass: true)
        ghost.render(TabDragGhostMotion(rect: CGRect(x: 100, y: 100, width: 160, height: 28), cardness: 0))
        let root = try #require(ghost.panel.contentView)
        let glass = try #require(root.subviews.first { $0 is GlassPanelView })
        #expect(glass.alphaValue == 1, "the tab is glass while it is a tab, not only once the card unfolds")
        #expect(glass.frame.size == CGSize(width: 160, height: 28))

        let solid = TabDragGhostPanel(tabImage: nil, tabSize: CGSize(width: 160, height: 28),
                                      grabOffset: CGPoint(x: 20, y: 14), aspect: 1.6, scale: 2, onGlass: false)
        solid.render(TabDragGhostMotion(rect: CGRect(x: 100, y: 100, width: 160, height: 28), cardness: 0))
        let solidGlass = try #require(solid.panel.contentView?.subviews.first { $0 is GlassPanelView })
        #expect(solidGlass.alphaValue == 0, "an opaque window's tab image carries its own card")
    }

    /// Runs `body` with the app theme opaque and without art, so only a workspace's own pin can
    /// make a drag preview glass.
    func opaqueAppWithoutArt<T>(_ body: () throws -> T) rethrows -> T {
        let original = ThemeScope.app.store.input
        let originalSelection = ThemeScope.app.backdropSelection
        defer {
            _ = ThemeScope.app.store.apply(original)
            ThemeScope.app.setBackdropSelection(originalSelection)
        }
        var input = original
        input.backgroundOpacity = 1
        input.backgroundBlur = 0
        _ = ThemeScope.app.store.apply(input)
        ThemeScope.app.setBackdropSelection(nil)
        return try body()
    }

    /// Review of #22202: the drag ghost read the APP scope while the images under it are drawn in
    /// the SOURCE scope, so a workspace with art of its own over an opaque app dropped its card
    /// for glass and the ghost then drew no glass under it. Every source now hands its own
    /// scope's answer to the ghost: a strip's tab image, and the ghost the drag session flies for a
    /// sidebar row's handoff.
    @Test func aWorkspacesOwnBackgroundDecidesTheGhostsGlassNotTheApps() async throws {
        opaqueAppWithoutArt {
            #expect(WindowBackdrop.dragPreview(ThemeScope.app).isOpaque, "the fixture's app is opaque")
            let workspace = ThemeScope(level: .workspace)
            workspace.pinBackdrop(.selection(.art(.friedrichForestMoonlight)))
            let glass = !Self.reducesTransparency
            #expect(WindowBackdrop.dragPreview(workspace).dragsOnGlass == glass)

            // A strip in the workspace: its tab image is drawn for glass.
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: TabStripView.preferredHeight))
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host
            workspace.root(host)
            let strip = TabStripView(model: TabStripModel(tabs: [TabItem(id: TabID("t"), title: "cmux")], selectedID: TabID("t")))
            strip.frame = host.bounds
            host.addSubview(strip)
            #expect(strip.snapshot(of: [], frame: CGRect(x: 0, y: 0, width: 160, height: 28)).onGlass == glass)
        }

        // The drag session's ghost follows the handoff, not the app's opaque theme.
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "k1"), name: "k1"),
        ])
        tree.personal = PersonalState(workspaces: [
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "k1"), index: 0),
        ])
        store.apply(snapshot: tree)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"drag-glass","workspace_key":"k1"}"#.utf8))
        let state = WindowState(record: record)
        services.windows.registry.provisional[state.id] = ["k1"]
        let controller = WindowController(state: state, services: services, frame: NSRect(x: 200, y: 200, width: 1100, height: 720))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        let session = services.dragSession
        for onGlass in [true, false] {
            try opaqueAppWithoutArt {
                let handoff = SidebarDragHandoff(payload: .workspaces([WorkspaceID("k1")]), workspaceIDs: [WorkspaceID("k1")],
                                                 rowScreenFrame: CGRect(x: 300, y: 300, width: 220, height: 28),
                                                 grabOffset: CGPoint(x: 20, y: 14), screenPoint: CGPoint(x: 320, y: 314),
                                                 image: nil, imageOnGlass: onGlass)
                #expect(session.beginWorkspaces(handoff, from: controller))
                let ghost = try #require(session.drag?.ghost)
                #expect(ghost.onGlass == onGlass, "the ghost stands on the glass its image was drawn for")
                session.finish(commit: false)
                session.finishLanding()
            }
        }
    }

    /// The boundary: a window opened later (a torn-off workspace or tab) with its own room scope
    /// showing a new workspace scope gets the main window's window opacity, background, blur and
    /// material, through the one install path every main window takes.
    @Test func aNewSecondaryWindowHasTheMainWindowsBackdrop() throws {
        try translucent {
            @MainActor func open() -> (NSWindow, WindowRootView, ThemeScope) {
                let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel()),
                                          reduceTransparency: { false }, applyWindowBlur: { _, _ in })
                let window = NSWindow(contentRect: root.frame,
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let room = ThemeScope(level: .room)
                window.install(kind: .main, content: root, scope: room)
                return (window, root, room)
            }
            let (main, mainRoot, _) = open()
            defer { main.close() }
            let (torn, tornRoot, tornRoom) = open()
            defer { torn.close() }
            let workspace = ThemeScope(level: .workspace)
            tornRoom.show(workspace)
            mainRoot.themeDidChange()
            tornRoot.themeDidChange()

            #expect(!mainRoot.backdrop.isOpaque)
            #expect(tornRoot.backdrop == mainRoot.backdrop)
            #expect(torn.isOpaque == main.isOpaque)
            #expect(!torn.isOpaque)
            #expect(torn.backgroundColor == main.backgroundColor)
            #expect(tornRoot.backdropView.material == mainRoot.backdropView.material)
            #expect(tornRoot.backdropView.tintColor == mainRoot.backdropView.tintColor)
            #expect(tornRoot.layer?.backgroundColor == nil, "no solid sheet under a translucent window's content")
        }
    }
}
