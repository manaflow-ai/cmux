import struct CmuxSafeConcurrency.OwnerReference
import AppKit
import CmuxNextCompatAppKit
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextHomeEngine
import CmuxNextLaunch
import CmuxNextSettings
import CmuxNextTerminal
import CmuxNextWakeups
import os
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// Runs a quit (user decision 2026-09-30). `applicationShouldTerminate`
/// hands every quit here: it takes the origin (`QuitOriginTracker`), reads
/// the local terminals for an interactive quit, decides (`QuitPolicy`),
/// shows `QuitAlert` when asked to, then completes (`QuitCompletion`):
/// remember the choice, save and close windows, and for End end the local
/// terminals and stop the local daemon. A failed end step shows
/// `QuitFailureAlert` (Retry or Quit Anyway). Remote sessions are never ended.
@MainActor
final class QuitCoordinator {
    let origins: QuitOriginTracker
    private(set) var sheet: QuitAlert?
    /// "Some sessions did not end", while it shows.
    private(set) var failureAlert: QuitFailureAlert?
    /// A quit is in progress (deciding, asking or completing).
    private(set) var isQuitting = false
    /// The last dialog brought the app forward (`debug.quit`).
    private(set) var lastAskActivated = false
    /// The browser tabs that held Secure Input as this quit began, before any dialog took the keyboard: they leave
    /// no launch picture (`TabContentCache.secureInputPages`).
    private var secureInputPages: Set<String> = []
    private let servicesReference: OwnerReference<AppServices>
    /// The app's services, which own this; nil (reported) only once they are gone.
    private var services: AppServices? { servicesReference.resolve() }
    /// The quit hook's participants (`AppServices.quitUnsaved`; tests replace it).
    var unsaved: QuitUnsavedRegistry
    /// The app's main-thread watchdog (AppDelegate): a quit that is ending
    /// stops its debug hang assertion and records its open field interval.
    weak var watchdog: MainThreadWatchdog?
    /// Ends the process if the engine stop never returns (cx-ccjnn).
    let deadline = QuitDeadline()
    #if DEBUG || CMUX_BENCH_HOOKS
    /// `debug.quit {wedge_engine_stop: true}`: the next quit's engine stop
    /// blocks the main thread for good, as a wedged CefShutdown did (cx-ccjnn).
    var wedgesEngineStop = false
    #endif
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.quit")

    init(services: AppServices) {
        servicesReference = OwnerReference(services: services)
        unsaved = services.quitUnsaved
        origins = QuitOriginTracker(workspaceEvents: services.workspaceEvents)
    }

    /// Records the origin, then starts AppKit's termination. A second Cmd-Q
    /// while the dialog asks confirms its default (keep); a quit already
    /// completing ignores a repeat.
    func requestQuit(_ origin: QuitOrigin) {
        guard !isQuitting else {
            if origin == .interactive { sheet?.answerDefault() }
            return
        }
        origins.record(origin)
        // From a run-loop callout, not from inside the caller's main-queue
        // job (control socket, palette): terminateLater spins a nested run
        // loop, and the save Task could never get the main queue.
        NSApplication.terminateFromRunLoop { SheetDismissal.endAll() }
    }

    /// SIGTERM, SIGINT, SIGHUP (`QuitSignal`): Quit, keep sessions, never an alert. Dev
    /// tooling quits tagged apps this way (scripts/lib/stop-app-instances.sh)
    /// and must never wait on the alert. An open alert is answered with
    /// keep; a quit already completing is left to finish.
    func terminateFromSignal() {
        if let sheet { return sheet.answerKeepingSessions() }
        if let failureAlert { return failureAlert.answerQuitAnyway() }
        guard !isQuitting else { return }
        requestQuit(.signal)
    }

    func shouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isQuitting else {
            // A second Quit that reached AppKit directly (Dock, menu).
            sheet?.answerDefault()
            return .terminateLater
        }
        // No services: nothing is left to save or ask about.
        guard let services else { return .terminateNow }
        isQuitting = true
        secureInputPages = services.cache.secureInputPages()
        // Quit (menu, Cmd-Q, socket) never waits on another open sheet.
        SheetDismissal.endAll()
        let origin = origins.consume(appleEventReason: Self.quitReason())
        let behavior = services.settings?.snapshot.quitBehavior ?? QuitBehaviorSetting.fallback
        logger.info("quit origin=\(String(describing: origin), privacy: .public) behavior=\(behavior.rawValue, privacy: .public)")
        // [services]: the quit task pins the app's services until it ends (cx-6so P1b). The rest of the quit a person
        // (or the system) asked for, at user-blocking priority; it drains BackgroundWork itself, so shutdown lets it run on.
        // The body is main-actor (decideQuit); the task captures only Sendable values.
        services.work.task(.userBlocking, shutdown: .continueOnShutdown) { [self, services] in
            await decideQuit(origin, behavior: behavior, sender, services: services)
            withExtendedLifetime(services) {}
        }
        return .terminateLater
    }

    /// The rest of `shouldTerminate(_:)`'s quit: the unsaved step, then the policy's answer.
    private func decideQuit(_ origin: QuitOrigin, behavior: QuitBehavior, _ sender: NSApplication, services: AppServices) async {
        // Unsaved documents come first (R96 quit hook). Answering that
        // question is the quit's one dialog: the sessions are not asked
        // about after it (#17501).
        let askedUnsaved = origin == .interactive && !unsaved.unsaved().isEmpty
        guard await resolveUnsaved(origin, services: services) else {
            isQuitting = false
            sender.reply(toApplicationShouldTerminate: false)
            return
        }
        let facts = QuitPolicy.needsFacts(origin) && !askedUnsaved ? await QuitFactsReader.read(services) : .none
        switch QuitPolicy.decide(origin, behavior: behavior, facts: facts, alreadyAsked: askedUnsaved) {
        case .quit(let choice):
            await complete(choice, remember: false, sender, services: services)
        case .ask(let prompt):
            ask(prompt, sender, activate: Self.shouldActivate(origin, isActive: NSApp.isActive,
                                                              noActivate: WindowPlacement.noActivate), services: services)
        }
    }

    /// The unsaved step for `origin` (`QuitUnsavedStep.resolve`).
    private func resolveUnsaved(_ origin: QuitOrigin, services: AppServices) async -> Bool {
        let window = sheetWindow()
        return await QuitUnsavedStep.resolve(origin, registry: unsaved, scope: window.map { .window($0) } ?? .app, work: services.work,
                                             writeDrafts: { [drafts = services.recoveryDrafts] in await drafts.writePending() })
    }

    /// A quit from the Dock or the app switcher while cmux is inactive is the
    /// user's: cmux comes forward so the dialog is seen. Never in a
    /// no-activate launch; non-interactive quits never ask.
    static func shouldActivate(_ origin: QuitOrigin, isActive: Bool, noActivate: Bool) -> Bool {
        origin == .interactive && !isActive && !noActivate
    }

    private func ask(_ prompt: QuitPrompt, _ sender: NSApplication, activate: Bool, services: AppServices) {
        lastAskActivated = activate
        if activate { NSApp.activate() }
        let sheet = QuitAlert(prompt: prompt) { [weak self, weak services] answer in
            guard let self else { return }
            self.sheet = nil
            switch answer {
            case .cancel:
                self.isQuitting = false
                sender.reply(toApplicationShouldTerminate: false)
            case .quit(let choice, let remember):
                // No services: nothing is left to save.
                guard let services else { return sender.reply(toApplicationShouldTerminate: true) }
                // The rest of the person's answer, as above: it drains BackgroundWork itself.
                services.work.task(.userBlocking, shutdown: .continueOnShutdown) { [self, services] in
                    await complete(choice, remember: remember, sender, services: services)
                    withExtendedLifetime(services) {} // pins the app's services until the quit ends
                }
            }
        }
        self.sheet = sheet
        sheet.present(in: sheetWindow())
    }

    private func complete(_ choice: QuitSessionsChoice, remember: Bool, _ sender: NSApplication, services: AppServices) async {
        logger.info("quit choice=\(choice.rawValue, privacy: .public) remember=\(remember)")
        let secureInputPages = secureInputPages
        // Sparkle installs a staged update as the app exits unless
        // `updates.installOnQuit` is off (then its installer is cancelled now).
        services.updater.prepareForQuit()
        // From here the quit is decided: an end before AppKit's reply (a
        // SIGKILL after a bounded wait, a slow Chromium shutdown) is still
        // a quit the user asked for, not a crash.
        // A quit while inactive records its idle period now, before any quit work or the daemon's stop is in it.
        services.idleWakeups?.reportTriggered()
        // Awaited (bounded) so `quitting` is on disk before the quit can end
        // the process; the write itself runs off the main thread.
        await services.crashRecovery.quitBegan()
        #if DEBUG || CMUX_BENCH_HOOKS
        let wedgeIfAsked: @MainActor () -> Void = { [weak self] in
            if let self, wedgesEngineStop { deadline.wedgeMainThread(watchdog) }
        }
        #else
        let wedgeIfAsked: @MainActor () -> Void = {}
        #endif
        await QuitCompletion.run(choice, remember: remember, QuitSteps(
            remember: { behavior in
                guard let settings = services.settings,
                      let descriptor = SettingsSchema.descriptor(for: QuitBehaviorSetting.configPath) else { return }
                do { try await settings.setSetting(descriptor, to: .string(behavior.rawValue), by: .user) } catch {
                    Logger(subsystem: "com.cmuxterm.app.next", category: "app.quit")
                        .error("quit setting write failed: \(String(describing: error), privacy: .public)")
                }
            },
            prepareWindows: {
                // Remote-terminal tabs keep their last screen for the
                // placeholder after relaunch (data-model.md 1.4).
                await services.madeRemoteTerminals?.saveSnapshots()
                // Agent chats get their composer's chips, shell command and place back at the next
                // launch (pages are asked at once, each within a second).
                await services.agentTabs.relaunchWake.save(services.agentTabs.relaunchWakeStates())
                // Agent panes on screen draw their last page at the next launch.
                let agentPages = await services.agentTabs.shownPageImages()
                await services.agentTabs.launchImages.save(agentPages)
                let terminalStore = services.terminalLaunchFrames
                let terminalFrames = await terminalStore.frames(of: services.cache.terminals.mapValues(\.session))
                await terminalStore.save(images: terminalFrames)  // and terminals their last frame
                // And browser pages theirs (`browserLaunchPictures`; with it off, the last quit's pictures go).
                var pageShots: [BrowserLaunchPictures.Shot] = []
                if let pictures = services.environment.browserLaunchPictures {
                    if services.cache.launchPictures != nil {
                        pageShots = await services.cache.launchPictureShots(Self.launchPicturePanes(services), secureInput: secureInputPages)
                    }
                    await pictures.save(pageShots)
                }
                // And each window one picture of it (`savedWindowPicture`, `launch.savedPicture`; either off, the last quit's go).
                if let windowPictures = services.environment.windowPictures {
                    let pages = Dictionary(pageShots.map { ($0.key, $0.picture) }, uniquingKeysWith: { first, _ in first })
                    let savedPicture = services.settings.flatMap { $0.loadCount >= 1 ? $0.snapshot.savedPicture : nil }
                    await windowPictures.saveAtQuit(featureOn: services.features.isEnabled(.savedWindowPicture), savedPicture: savedPicture) {
                        // Checked again after the page captures: Secure Input may have begun while they ran.
                        let secureInput = services.cache.composeSecureInputPages(quitBegan: secureInputPages)
                        return Self.windowPictureShots(services, terminals: terminalFrames, agents: agentPages, pages: pages, secureInput: secureInput)
                    }
                }
                // Browser tabs reopen at their recorded page (before any
                // session ends, while the daemon still answers).
                await services.cache.browserTabs.flushRecords()
                await services.windows.prepareForTermination()
                // A sidebar change whose idle task has not run yet is saved too.
                await services.windows.flushSidebarSnapshots()
                await services.sidebarSnapshots.flush()
                // Home's drafts, scroll places and unsent sends (its cache's last batch).
                await services.home.flushCacheForQuit()
            },
            endLocalSessions: { await services.daemon.endSessionsAndStop($0) },
            confirmFailures: { [weak self] failures in await self?.confirm(failures) ?? .quitAnyway },
            endLocalAgents: { [attempts = QuitAttempts()] in
                // The Chief home's host ends with the sessions (home-state-ownership.md section 3),
                // and Home does not start it again.
                await services.home.brain.stop()
                let acpmux = await QuitAgents.resolvedEnvironment(services)
                // A Chief home whose acpmux is the attached daemon (`CMUX_NEXT_ACPMUX_ATTACH`) ends nothing there.
                if !QuitAgents.isAttached(acpmux, to: services.home.chief.home.acpmuxHome) {
                    await ChiefHostStop.endChiefSessions(home: services.home.chief.home,
                                                         bundledBin: Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true),
                                                         runner: services.work)
                }
                await services.home.chief.shutdownForEndSessions()
                let keep = ChiefHostStop.appAcpmuxEndKeep(chiefUsesAppAcpmux: services.home.chief.home.usesAppAcpmux)
                return await QuitAgents.end(acpmux, runner: services.work, keep: keep, waitForShutdown: attempts.isRetry())
            },
            // Drafts typed after the save step (while "Some sessions did not end" waited) reach disk
            // before the engines stop: nothing the user asked for comes after that (QuitSteps).
            // Nothing is written when nothing changed.
            lastSave: { await services.home.flushCacheForQuit() },
            armDeadline: { [weak self, deadline = self.deadline] in
                // CefShutdown runs on the main thread and can block it for
                // good: from here the quit ends by a deadline whatever it
                // does, and a debug build reports that hang, never asserts it.
                deadline.arm(after: QuitDeadline.engineStopLimit)
                self?.watchdog?.endHangAssertions()
                self?.watchdog?.recordFieldMetricsAtQuit()
            },
            beginDrain: { services.work.beginShutdown() },
            stopBrowserEngines: {
                wedgeIfAsked()
                await services.cache.chromium.shutdown()  // a never-built engine started no Chromium: none is built here
            },
            finishDrain: { await services.work.shutdown() }
        ))
        sender.reply(toApplicationShouldTerminate: true)
    }

    /// The panes on screen that show a tab, with their content area: in windows ordered in, not minimized, on the
    /// active Space and not full screen (a window's picture is never taken there either, p08-startup 3C).
    private static func launchPicturePanes(_ services: AppServices) -> [(key: String, host: NSView)] {
        services.windows.controllers.flatMap { controller -> [(key: String, host: NSView)] in
            guard let window = controller.window, VisiblePaneRefs.Window.isOnScreen(window), window.isOnActiveSpace,
                  !window.styleMask.contains(.fullScreen), let content = controller.content, !content.isParked else { return [] }
            return content.panes.values.compactMap { pane in
                guard let key = pane.currentTabKey, VisiblePaneRefs.Window.isOnScreen(pane.view) else { return nil }
                return (key, pane.view.contentHost)
            }
        }
    }

    /// Each open window's picture, from the pane pictures this quit took already, so nothing is
    /// captured twice. Side-by-side windows show panes of other workspaces than `content`'s: they leave none. A
    /// window showing a top page or the empty state leaves one with no pane (`WindowPictureMeta.ContentArea`).
    private static func windowPictureShots(_ services: AppServices, terminals: [String: NSImage], agents: [String: NSImage],
                                           pages: [String: BrowserLaunchPictures.Picture], secureInput: Set<String>) -> [WindowPictureStore.Shot] {
        let input = services.themeStore.input, build = WindowPictureMeta.build(of: .main)
        let theme = WindowPictureMeta.themeFingerprint(input: input, app: services.themeStore.appTheme ?? services.themeStore.tokens.app)
        let background = WindowPictureStore.Color(red: input.background.red, green: input.background.green, blue: input.background.blue)
        return services.windows.controllers.compactMap { controller -> WindowPictureStore.Shot? in
            let state = controller.state, root = controller.root
            let content = controller.content.flatMap { $0.isParked ? nil : $0 }
            guard let window = controller.window, state.viewSet == nil,
                  let area = WindowPictureMeta.ContentArea(page: state.page?.rawValue, workspaceID: state.workspaceID,
                                                           cloudCreating: state.cloudCreation != nil, contentShown: content != nil) else { return nil }
            var panes: [WindowPictureStore.Pane] = [], screens: [WindowPictureMeta.Screen] = []
            if case .workspace = area, let content {
                panes = content.panes.values.compactMap { pane in
                    pane.currentTabKey.map { key in
                        WindowPictureStore.Pane(key: key, area: pane.view.contentHost,
                                                content: .init(windowPictureSource(key, services, terminals: terminals, agents: agents,
                                                                                   pages: pages, secureInput: secureInput)))
                    }
                }
                screens = content.workspace.screens.map { WindowPictureMeta.Screen(id: $0.id, tree: .init($0.layout), zoomed: $0.zoomedPane?.description) }
            }
            let layout = area.layout(workspaces: services.windows.registry.members(of: state.id), screens: screens)
            let facts = WindowPictureStore.Window(id: state.id, profile: state.profileID.rawValue, incognito: services.windows.isIncognito(window: state.id),
                                                  theme: theme, background: background, build: build, layout: layout,
                                                  screen: window.screen.flatMap(WindowPlacementFallback.displayID(of:)))
            return WindowPictureStore.shot(of: window, root: root, backdrop: root.backdropView, sidebar: root.sidebarHidden ? nil : root.sidebar,
                                           panes: panes, facts: facts)
        }
    }

    /// What tab `key`'s pane shows, for its window's picture (`WindowPictureStore.Pane.Content(_:)` applies the
    /// privacy fills): a terminal's frame at its surface and whether it holds Secure Input, an agent's page over the
    /// pane, a browser page's picture at its page frame and whether it is withheld now (checked again: Secure Input
    /// may have begun while the page captures ran). AppKit draws the rest (cmux pages).
    private static func windowPictureSource(_ key: String, _ services: AppServices, terminals: [String: NSImage], agents: [String: NSImage],
                                            pages: [String: BrowserLaunchPictures.Picture], secureInput: Set<String>) -> WindowPictureStore.Pane.Source {
        func cgImage(_ image: NSImage?) -> CGImage? { image?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        if let session = services.cache.terminals[key]?.session {
            return .terminal(surface: session.surfaceView, frame: cgImage(terminals[key]), holdsSecureInput: session.holdsSecureInput)
        }
        if services.agentTabs.existingView(key) != nil, let page = agents[key], let image = cgImage(page) {
            return .agentPage(image, size: page.size)
        }
        return services.cache.windowPictureSource(key, picture: pages[key], secureInput: secureInput) ?? .cmuxPage
    }

    /// Shows "Some sessions did not end" and waits for the answer.
    private func confirm(_ failures: [EndSessionsFailure]) async -> QuitFailureAnswer {
        // An alert dropped unanswered quits anyway, as a coordinator gone does (`confirmFailures`).
        let chosen = try? await withOnceContinuation { (continuation: OnceContinuation<QuitFailureAnswer, OnceContinuationError>) in
            let alert = QuitFailureAlert(failures: failures) { [weak self] answer in
                self?.failureAlert = nil
                self?.logger.info("quit end failures answer=\(String(describing: answer), privacy: .public)")
                continuation.resume(returning: answer)
            }
            failureAlert = alert
            alert.present(in: sheetWindow())
        }
        return chosen ?? .quitAnyway
    }

    /// The active shell window when it can carry a sheet.
    private func sheetWindow() -> NSWindow? {
        guard let services else { return nil }
        let candidates = [services.windows.active?.window, NSApp.mainWindow] + services.windows.controllers.map(\.window)
        return candidates.compactMap { $0 }.first { $0.isVisible && !$0.isMiniaturized && $0.attachedSheet == nil }
    }

    /// `kAEQuitReason` of the quit Apple event being handled, if any.
    private static func quitReason() -> OSType? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication),
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) ?? event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        else { return nil }
        return reason.enumCodeValue
    }
}

extension WindowPictureMeta.PaneTree {
    /// The daemon's split tree, by pane handle (valid while the daemon that made them runs: a daemon started again
    /// renumbers its panes, and the picture's layout then does not match).
    nonisolated init(_ node: LayoutNode) {
        switch node {
        case .leaf(let pane):
            self = .leaf(pane.description)
        case .split(_, _, let direction, let ratio, let a, let b):
            self = .split(vertical: direction == .down, ratio: ratio, a: Self(a), b: Self(b))
        case .stack(let panes, let expanded):
            self = .stack(panes: panes.map(\.description), expanded: expanded.description)
        case .unknown:
            self = .unknown
        }
    }
}
