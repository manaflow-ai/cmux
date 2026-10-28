import AppKit
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextLaunch
import Foundation

/// The launch window drawn from the daemon's launch snapshot
/// (`launch-snapshot-v1`) before the daemon answers: the frontmost saved
/// window (frame, sidebar, shown workspace) when the snapshot has window
/// records, else one window listing every workspace of the snapshot's
/// tree. Terminals attach once connected; `WindowManager.restore` adopts
/// the same window, so the live tree replaces the snapshot in place.
///
/// With `savedWindowPicture` the saved window's first frame is its picture
/// from the last quit (`LaunchPicturePhase`): the window at
/// its saved frame, its live material and the picture, nothing else; its
/// controller and live views are built behind the picture after that frame,
/// slice by slice (`build(_:in:phase:)`).
struct LaunchSnapshotWindow {
    let manager: WindowManager

    /// Opens the launch window (`WindowManager.restoreWhenLoaded`, once the snapshot's read has ended): drawn from the
    /// snapshot, else in the connecting state, outside the registry. Nothing when a window or its picture is up.
    func openLaunchWindow() {
        guard manager.controllers.isEmpty, manager.launchPicture == nil, !show() else { return }
        let id = UUID().uuidString.lowercased()
        manager.launchWindowID = id
        manager.makeController(for: WindowRegistry.Window(id: id))
    }

    /// False when the snapshot has nothing to draw (or there is none).
    func show() -> Bool {
        let daemon = manager.services.daemon
        guard daemon.store.isProvisional else { return false }
        if let document = daemon.launchSnapshot.windows, showSaved(document) { return true }
        return showEveryWorkspace(daemon.store)
    }

    private func showSaved(_ document: WindowStateDocument) -> Bool {
        let saved = WindowRegistry(records: document.windows), machines = manager.services.machines
        guard let front = WindowStateDocument.frontWindow(of: document.windows, mirrors: { machines.workspace(id: $0) != nil })?.id,
              let record = document.windows.first(where: { $0.id == front }), let window = saved.window(front) else { return false }
        manager.launchWindowID = front
        manager.state(for: front).adopt(record)
        manager.registry.provisional[front] = window.workspaceIDs
        // Unregistered (no workspaces), so it is presented at once.
        open(WindowRegistry.Window(id: front, frame: window.frame, display: window.display))
        return true
    }

    /// No window records (an older snapshot, or none saved yet): the tree
    /// still says which workspaces exist, so the launch window lists them
    /// all until the restore assigns windows. Never after a crash that left
    /// incognito workspaces (the ledger's launch read lists them, has not
    /// ended, or found a file it could not read): they must not appear in a normal window, and the restore discards them.
    private func showEveryWorkspace(_ store: DaemonStore) -> Bool {
        let workspaces = store.workspaces.map(\.id)
        guard !workspaces.isEmpty, !manager.incognitoLedger.mayHaveLeftovers else { return false }
        let id = UUID().uuidString.lowercased()
        manager.launchWindowID = id
        manager.registry.provisional[id] = workspaces
        manager.makeController(for: WindowRegistry.Window(id: id))
        DebugTimings.markLaunch("launch_snapshot_shown")
        return true
    }

    // MARK: The saved picture

    /// Opens saved window `window`: as its picture once the picture's read ends (at most 40 ms on a `MainDeadline`;
    /// the main thread never waits) when the picture is that window's and its meta matches the window opened, else
    /// on today's path, its controller made now (no picture saved, the feature off, a window the quit leaves none
    /// of: full screen, side by side, test placement).
    private func open(_ window: WindowRegistry.Window) {
        let manager = manager, services = manager.services, state = manager.state(for: window.id)
        guard services.features.isEnabled(.savedWindowPicture), let pictures = services.environment.windowPictures,
              services.environment.testWindow == nil, window.frame != nil, !state.restoresFullScreen, state.viewSet == nil else {
            return openToday(window)
        }
        let phase = LaunchPicturePhase(deadlines: services.mainDeadlines) { DebugTimings.markLaunch($0) }
        manager.launchPicture = phase
        phase.start({ _ = await pictures.frontFinished() }, on: services.work, mainWork: services.mainWork) { _ in
            // `takeFront(matching:launch:)` hands out a picture whose read ended by now and that the launch rules
            // allow, or marks it missed or refused.
            LaunchSnapshotWindow(manager: manager).show(from: pictures, of: window, in: phase)
        }
    }

    private func openToday(_ window: WindowRegistry.Window) {
        manager.makeController(for: window)
        DebugTimings.markLaunch("launch_snapshot_shown")
    }

    private func show(from pictures: WindowPictureStore, of window: WindowRegistry.Window, in phase: LaunchPicturePhase) {
        let manager = manager, services = manager.services
        guard manager.launchPicture === phase else { return }
        // The window's room scope, themed as its controller's will be: its backdrop under the picture.
        let room = manager.state(for: window.id).profileID, scope = ThemeScope(level: .room)
        services.themes.setTheme(of: scope, to: services.themes.roomTheme(room))
        services.themes.applyWindowBackground(of: scope, room: room)
        guard let opening = pictureMeta(of: window, appearance: scope.appearance) else {
            pictures.dropFront()
            DebugTimings.markLaunch("launch_picture_mismatch")
            return skip(phase, window)
        }
        // The setting unknown (settings not loaded yet) shows no picture, as the quit saves none then.
        let settings = services.settings
        let facts = WindowPictureStore.LaunchFacts(savedPicture: settings.map { $0.loadCount >= 1 && $0.snapshot.savedPicture } ?? false,
                                                   recovered: services.crashRecovery.recovery.isRestart,
                                                   incognitoLeftovers: manager.incognitoLedger.mayHaveLeftovers,
                                                   savedScreensStale: !services.crashRecovery.relaunchReattach(features: services.features).keepsSavedScreens)
        // A refusal records its own `launch_picture_refused.<reason>` mark.
        guard let shown = pictures.takeFront(matching: opening, launch: facts), shown.picture.windowID == window.id else {
            return skip(phase, window)
        }
        // Stand-in until the launch builds stale regions live under the rest of the picture (p08-startup-063's
        // region refusal): a changed sidebar or pane layout takes today's path for the whole window, as 059 did.
        guard shown.stale.isEmpty else {
            DebugTimings.markLaunch("launch_picture_mismatch")
            return skip(phase, window)
        }
        let front = shown.picture
        let shell = ShellWindow.main(frame: opening.frame)
        shell.setFrame(opening.frame, display: false)  // contentRect grows by the titlebar: the saved frame exactly
        // Where its pages draw, before any overlay or panel of the picture reads it (as the controller sets it).
        shell.pageSurface = services.chromiumRuntime.source.backend.pageSurface
        // Before any view reaches the window, as the controller does: its visibility node, its key family.
        _ = services.appVisibility.windowNode(shell, name: "window:\(window.id)")
        WindowMaterialView.observeKeyFamily(of: shell, through: services.appEvents)
        // Keys and clicks wait for the window behind the picture.
        let state = manager.state(for: window.id)
        let input = LaunchPictureInput(window: window.id, shell: shell, keys: services.keyRouter.launchPictureKeys, reveal: services.launchReveal,
                                       mainWork: services.mainWork) { [weak state] in
            state.map { String(describing: ($0.workspaceID, $0.page, $0.sidebarHidden)) }
        }
        phase.show(front.image, in: shell, scope: scope, present: {
            guard manager.ordersWindowsIn else { return }
            services.background.windowWillAppear(activates: true)
            WindowActivation.show(shell, .present)
            DebugTimings.markLaunch("window_display")
            DebugTimings.markLaunch("launch_snapshot_shown")
        }, startup: services.launchStartup) { [weak manager, input] in
            guard let manager, manager.launchPicture === phase else { return }
            // Closed before it was built: as the launch window's close (`windowWillClose`), nothing to hand over.
            guard shell.isVisible || !manager.ordersWindowsIn else {
                phase.remove()
                manager.launchWindowID = nil
                manager.states[window.id] = nil
                return phase.skip()
            }
            LaunchSnapshotWindow(manager: manager).build(window, in: shell, phase: phase, input: input)
        }
        phase.whenRemoved { input.finish() }
    }

    /// Builds the launch window behind its picture: this slice makes its controller with its
    /// sidebar rows; its tab strips, focused pane and other visible panes follow, one afterFirstFrame post each
    /// (`LaunchWindowBuild`). The sidebar's part of the picture leaves at its first rows, each pane's at its own first
    /// content, the rest with the last of them. A key or a click on the picture raises the build (`input`).
    private func build(_ window: WindowRegistry.Window, in shell: ShellWindow, phase: LaunchPicturePhase, input: LaunchPictureInput) {
        let manager = manager, services = manager.services
        let controller = manager.makeController(for: window, in: shell), root = controller.root, reveal = services.launchReveal
        guard let regions = phase.adopt(root: root, reveal: reveal) else {
            controller.goLive()
            return phase.buildFinished()
        }
        root.launchPictureRegions = regions
        if let picture = phase.picture { input.holdClicks(on: picture, regions: regions) }
        let sidebar = root.sidebar
        let sidebarPart = regions.add { [weak sidebar] picture in
            guard let sidebar, !sidebar.isHidden else { return .zero }
            return sidebar.convert(sidebar.bounds, to: picture)
        }
        reveal.whenProduced(.sidebar) { [weak regions] in regions?.leave(sidebarPart) }
        let startup = services.launchStartup
        let mainWork = services.mainWork
        let build = LaunchWindowBuild(window: controller, regions: regions, reveal: reveal, post: { name, work in
            guard let startup else { return work() }
            startup.post(.afterFirstFrame, name, on: .main, work)
        }, urgent: { name, work in mainWork.post(.userBlocking, owner: "\(name)", work) }) { phase.buildFinished() }
        input.build = build
        phase.whenRemoved { build.stop() }
        build.start()
    }

    /// No picture shows (none in time, another window's, a mismatch): the window opens as today.
    private func skip(_ phase: LaunchPicturePhase, _ window: WindowRegistry.Window) {
        manager.launchPicture = nil
        openToday(window)
        phase.skip()
    }

    /// What the quit's meta of `window` says when its picture shows this launch's window
    /// (`QuitCoordinator.windowPictureShots`): the saved frame placed as `makeController` places it, the display that
    /// shows most of it and its scale, the room's appearance, the theme, the sidebar's width and the layout from the
    /// launch snapshot. Nil without a saved frame, or a sidebar width while it shows. The regions are not compared.
    func pictureMeta(of window: WindowRegistry.Window, appearance: NSAppearance) -> WindowPictureMeta? {
        let services = manager.services, state = manager.state(for: window.id)
        guard let saved = window.frame, let sidebarWidth = state.sidebarHidden ? 0 : state.sidebarWidth else { return nil }
        let frame = WindowPlacementFallback.visible(saved, display: window.display)
        func overlap(_ screen: NSScreen) -> CGFloat {
            let shared = screen.frame.intersection(frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        let screen = NSScreen.screens.max { overlap($0) < overlap($1) }
        let shown = state.workspaceID.flatMap { services.machines.workspace(id: $0)?.0 }
        let layout = WindowPictureMeta.Layout(
            workspaces: manager.registry.members(of: window.id), shown: state.page.map { "page:\(String(describing: $0))" } ?? state.workspaceID,
            screens: shown?.screens.map { WindowPictureMeta.Screen(id: $0.id, tree: .init($0.layout), zoomed: $0.zoomedPane?.description) } ?? [])
        let input = services.themeStore.input
        let theme = WindowPictureMeta.fingerprint([String(describing: input), String(describing: services.themeStore.appTheme)])
        return WindowPictureMeta(
            window: window.id, profile: state.profileID.rawValue, frame: frame, screen: screen.flatMap(WindowPlacementFallback.displayID(of:)),
            scale: Double(screen?.backingScaleFactor ?? 1), appearance: appearance.name.rawValue, theme: theme,
            sidebarWidth: sidebarWidth, build: WindowPictureMeta.build(of: .main), layout: layout, regions: [])
    }
}

extension ShellWindow {
    /// A main window as every cmux window is made: titled with its title hidden over full-size content, at `frame`
    /// (its controller centers it when nil). The launch's picture window is made here too, so its titlebar and
    /// traffic lights are the live window's.
    static func main(frame: NSRect?) -> ShellWindow {
        let window = ShellWindow(
            contentRect: frame ?? NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = Strings.appName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 520, height: 320)
        window.isReleasedWhenClosed = false
        window.isRestorable = false  // cmux restores its windows from the daemon and the window registry, not AppKit
        window.tabbingMode = .disallowed
        return window
    }
}

/// The launch window as its build behind the picture makes it.
extension WindowController: LaunchBuiltWindow {
    /// The second slice: the shown workspace's layout and its panes' tab strips, laid out now so each pane has its
    /// area; each pane's content waits for its own slice. The focused pane first, then the others on screen.
    func mountLaunchStrips() -> [any LaunchWindowPane] {
        showWorkspace(requested: state.workspaceID)
        guard let content else { return [] }
        // sync-layout: the next lines need the panes the viewport shows (their presence) and their areas for the picture's parts; this slice's own pass
        root.layoutSubtreeIfNeeded()
        let focused = content.focusedPane
        let others = content.layoutModel.screens.flatMap(\.layout.panes).compactMap { content.panes[$0] }.filter { $0.isVisible && $0 !== focused }
        return (focused.map { [$0] } ?? []) + others
    }

    /// The build ended: the window follows its workspace, and each pane it did not show shows as usual.
    func goLive() {
        guard !tornDown else { return }
        if workspaceObservation == nil { observeWorkspace() }
        for pane in content.map({ Array($0.panes.values) }) ?? [] { pane.releaseFromLaunch() }
    }
}
