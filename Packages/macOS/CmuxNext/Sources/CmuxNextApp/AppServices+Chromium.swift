import AppKit
import CmuxNextBrowser
import CmuxNextChromiumWarmup
import CmuxNextCompat
import CmuxNextCrashReporting
import CmuxNextFeatures
import CmuxNextSettings
import CmuxNextWakeups
import Observation

// When Chromium is likely (ChromiumWarmup): Chromium tabs and the palette's Chromium
// entries (while Chromium is the default engine it starts after launch). The "+" engine menu reports from
// PaneController.contextMenu(for: .newTabButton), the default-engine action
// from SettingsHandlers.
extension AppServices {
    /// The cmux-shipped uBlock Origin's pinned folder (``AgentExtensionAccess/readTrustedBuiltInFolder(resources:)``,
    /// a manifest read and hash), read once on `work`'s files lane: each tab's extension access
    /// (``AppBrowserHostTabs/access(forTab:)``) and the Allow Agents prompt read it in memory (p02-threads-122).
    static func preloadBuiltInAdBlockerFolder(on work: BackgroundWork) -> PreloadedValue<String?> {
        let folder = PreloadedValue<String?> { AgentExtensionAccess.readTrustedBuiltInFolder() }
        work.post(.userVisible, mayBlock: .files) { folder.load() }
        return folder
    }

    /// Chromium's spare policy from the features, before anything can start Chromium: its switches read
    /// them at start (`CEFRuntime.initialize`), and the first spare window its placeholder's kind.
    func configureChromiumSpares() {
        let spareAfterFirstTab = features.isEnabled(.chromiumSpareAfterFirstTab)
        cache.cef.spareAfterFirstTab = { spareAfterFirstTab }
        // A spare's placeholder has no renderer where the fork can (p13-webui-019).
        cache.cef.setRendererlessSpareWindows(features.isEnabled(.rendererlessSpareWindow))
        // At most one Chromium spare renderer: Chromium's own, or the placeholder's (p07-memory-113).
        cache.cef.setOneSpareRenderer(features.isEnabled(.chromiumOneSpareRenderer))
    }

    /// Starts the launch preload and the likelihood observers. With the Chromium Host, Chromium's start holds the
    /// main thread only for its shim calls (the host spawns and attaches off main, the start's disk reads run off
    /// main), so once the launch's restore finished, one startup post starts it where ``ChromiumHostLaunchStart``
    /// puts it, with no idle wait (``ChromiumHostLaunchSlot``, p08-startup-046); the warm-up, armed in the same post,
    /// cannot start it sooner.
    func startChromiumWarmup() {
        guard chromiumRuntime.source.backend == .host, let launchStartup else { return armChromiumWarmup() }
        let preference = cache.browserTabs.preference
        let slot = ChromiumHostLaunchSlot(startup: launchStartup, decide: { [weak self] in
            guard let self else { return nil }
            return ChromiumHostLaunchStart(showsChromiumPane: showsChromiumPane, defaultIsChromium: preference.defaultEngine == .chromium,
                                           hasChromiumTab: machines.hasChromiumTab)
        }, start: { [weak self] start in
            self?.armChromiumWarmup()
            self?.chromiumWarmup.startWithoutIdleWait(start.reason)
        }, noStart: { [weak self] in self?.armChromiumWarmup() })
        windows.whenRestored { slot.restored() }
    }

    /// A shown window's pane shows a Chromium tab: a restored Chromium page the person sees.
    private var showsChromiumPane: Bool {
        windows.controllers.contains { controller in
            controller.visibility.isVisible
                && controller.content?.panes.values.contains { $0.selectedTab?.browserEngine == BrowserEngineTag.cef.rawValue } == true
        }
    }

    /// Arms the warm-up: its launch timer, the likelihood observers and the spare windows.
    private func armChromiumWarmup() {
        let machines = machines
        let preference = cache.browserTabs.preference
        // cmux pages follow `browser.defaultEngine` (ChromiumPageHost): with the feature, their profile
        // keeps a spare window too, so a page's key joins a live window (p13-webui-016).
        let pagesSpare = features.isEnabled(.pagesSpareWindow)
        chromiumWarmup.start(defaultIsChromium: { preference.defaultEngine == .chromium },
                             pagesPending: { [weak cache] in cache?.hasPendingPages == true },
                             pagesSpare: { pagesSpare && preference.defaultEngine == .chromium })
        cache.onPagesSettled = { [weak chromiumWarmup] in chromiumWarmup?.pagesSettled() }
        if pagesSpare {
            // Pages follow the default engine: switched away from Chromium, the untaken pages spare
            // closes; switched back, the next idle moment builds it again. The current value is
            // the one `start` already reads; only changes act (the first apply is that value).
            var started = false
            pagesSpareWatch = ServiceObservation(.background, owner: "ChromiumWarmup.pagesSpare", on: mainWork) {
                preference.defaultEngine == .chromium
            } apply: { [weak self] _ in
                if started { self?.chromiumWarmup.pagesSpareChanged() } else { started = true }
            }
        }
        chromiumLikelyObservations.append(Task { [weak self] in
            // A Chromium tab in any window, restored or created elsewhere. While Chromium is the
            // default engine the launch warm start covers every tab (ChromiumWarmup.start), so the
            // walk of every tab, which tracks every tab and re-runs on any tab change, is skipped:
            // only the default engine is read (pl-o-all, O(all) observers).
            for await reason in ObservationStream({ preference.defaultEngine == .chromium ? nil : Self.likelyFromTabs(machines) }) {
                guard let reason else { continue }
                self?.chromiumWarmup.chromiumLikely(reason)
                return
            }
        })
        palettes.whenBuilt { [weak self] palette in  // the palette is built after launch (p08-startup-023)
            guard let self else { return }
            lifetimeFollowers.append(ChromiumPaletteSignal(palette.model, warmup: chromiumWarmup, on: mainWork))
        }
    }
}

// The cache's Chromium engine (p08-startup-024): built at its first read, a Chromium tab or page or the warm-up
// above, never by launch wiring, and wired as it is built.
extension AppServices {
    /// The slot `cache` holds.
    func makeChromiumSlot() -> ChromiumEngineSlot {
        let pumpInput = features.isEnabled(.cefPumpInputPolicy) ? CEFPumpInputSeams(mainWork: mainWork) : nil
        // The lanes whose startup fence holds a predicted start's framework read (p08-startup-045).
        let prefetchWork = features.isEnabled(.cefPrefetchBehindFence) ? work : nil
        let mergeWork = features.isEnabled(.cefMergedEvents) ? mainWork : nil // page events per frame (p06-scheduler-219)
        // Host mode only: the host's widgets in cmux panels and panes (p01-process-066).
        chromiumRuntime.source.showsHostWidgets = features.isEnabled(.chromiumHostWidgets)
        // Host mode only: drags onto a page as Chrome's own drop (p01-process-050).
        chromiumRuntime.source.takesHostDrags = features.isEnabled(.chromiumHostDragIn)
        chromiumRuntime.source.fencesHostResizes = features.isEnabled(.chromiumHostResizeFence) // p01-process-052
        // Host mode only: <select> popups as cmux menus (p01-process-060).
        chromiumRuntime.source.drawsHostPopupMenus = features.isEnabled(.chromiumHostPopupMenus)
        chromiumRuntime.source.drawsHostSuggestions = features.isEnabled(.chromiumHostSuggestions) // p01-process-061
        // Host mode only: page file choosers in cmux's picker, the files sent as paths (p01-process-064).
        chromiumRuntime.source.hostFileDialogs = features.isEnabled(.chromiumHostFileDialogs) ? ChromiumFileDialogPanels(openPanel: openPanel) : nil
        // Restored pages start Chromium by their origin, the visible one after the first frame (p08-startup-040).
        let launchOrder = features.isEnabled(.cefLaunchOrigin) ? launchStartup : nil
        return ChromiumEngineSlot(stores: browserStores, waitDeadlines: mainWork.wakeUps, source: chromiumRuntime.source, launch: launchOrder,
                                  make: { [signInCallbacks, contextMenus, inputTap, crashKeys, launchStartup, launchOrder, pointerFrames = dragFrameInput,
                                           chromiumFeatures = features.enabledChromiumFeatures,
                                           disabledChromiumFeatures = features.disabledChromiumFeatures, layerHosting = features.isEnabled(.cefLayerHosting),
                                           attachedPages = features.isEnabled(.cefAttachedPages), memoryCoordinator,
                                           everyPage = Self.hostsEveryPage(features)] stores, deadlines, source in
                                      // Chromium's start as launch marks (p08-startup-044); its first page paint counts until startup_complete.
                                      let launchMarks = CEFLaunchMarkHooks(receive: { DebugTimings.markLaunch($0) },
                                                                           isStarting: { launchStartup.map { $0.completion == nil } ?? false })
                                      return CEFEngine(source: source, stores: stores, signInCallbacks: signInCallbacks, lifecycleTrace: .shared,
                                                       contextMenus: contextMenus, waitDeadlines: deadlines, input: inputTap, crashKeys: crashKeys,
                                                       launchMarks: launchMarks, pumpInput: pumpInput, pointerFrames: pointerFrames,
                                                       chromiumFeatures: chromiumFeatures, disabledChromiumFeatures: disabledChromiumFeatures,
                                                       prefetchWork: prefetchWork,
                                                       launch: launchOrder).usingLayerHostingByDefault(layerHosting).usingAttachedPages(attachedPages)
                                          .hostingEveryPage(everyPage).votingMemoryPressure(of: memoryCoordinator).mergingEvents(on: mergeWork)
                                  },
                                  engineDidCreate: AppServices.chromiumEngineHook(crashRecovery: crashRecovery, reporter: crashReporting.reporter,
                                                                                  routes: { [weak self] in self?.routeChromiumRequests($0) }),
                                  stop: { await $0.shutdown() })
    }

    /// Bench-only feature `cefLayerHostingEveryPage`, the layer hosting benches' on arm: compiled out of shipped builds.
    nonisolated static func hostsEveryPage(_ features: FeatureList) -> Bool {
        #if DEBUG || CMUX_BENCH_HOOKS
        features.isEnabled(.cefLayerHostingEveryPage)
        #else
        false
        #endif
    }

    /// The slot's `engineDidCreate`. It holds the crash services themselves, not the `AppServices`, so on every engine
    /// built, before CefInitialize can run: the crash log's writer, the run marker's and Sentry's signal handlers (Chromium
    /// resets them at start), the assistive-client switch of Chromium's accessibility trees; then `routes`.
    static func chromiumEngineHook(crashRecovery: CrashRecoveryService, reporter: CrashReporter,
                                   routes: @escaping (CEFEngine) -> Void) -> (CEFEngine) -> Void {
        { engine in
            crashRecovery.observe(engine.crashLog)
            AppRunMarker.keepSignalHandlers(crashRecovery.marker, across: engine, reporter: reporter)
            (NSApp as? CmuxApplication)?.assistiveClientsChanged = { [weak engine] active in engine?.setAssistiveClientActive(active) }
            routes(engine)
        }
    }

    /// Chromium's requests for a window: a link with no window for its (normal) profile opens as a new browser tab
    /// in the focused pane of a normal window, in the requesting page's browser profile; an incognito request opens
    /// in a cmux incognito window. Chromium opens nothing itself.
    private func routeChromiumRequests(_ engine: CEFEngine) {
        engine.openURLWithoutWindow = { [weak self] url, disposition, profile in
            self?.normalWindowForPageRequest()?.focusedPane?.newBrowserTab(url: url, background: disposition == .backgroundTab,
                                                                          profile: profile.map(BrowserProfileRecord.wireID(for:)))
        }
        engine.openOffTheRecord = { [weak self] url, source in self?.openOffTheRecord(url, source: source) }
    }
}

extension AppServices {
    /// Why the open tabs make a Chromium tab likely, nil when they do not.
    static func likelyFromTabs(_ machines: MachineRegistry) -> ChromiumWarmup.Reason? {
        machines.hasChromiumTab ? .restoredTab : nil
    }
}

extension MachineRegistry {
    /// True when any workspace of any machine holds a Chromium tab.
    var hasChromiumTab: Bool {
        allWorkspaces.contains { workspace, _ in
            workspace.screens.contains { screen in
                screen.panes.contains { pane in
                    pane.tabs.contains { $0.browserEngine == BrowserEngineTag.cef.rawValue }
                }
            }
        }
    }
}
