import Foundation

/// Browser-process command-line switches for the embedded Chromium.
nonisolated struct CEFSwitches: Equatable, Sendable {
    /// `cmux_cef_api_version()`; 0 for stock CEF.
    var forkAPIVersion: Int32
    /// The fork and shim have the renderer paths (`CEFForkFeatures.rendererPaths`): no tab keeps a
    /// DevTools session, so the per-renderer reuse switch applies.
    var rendererPaths = false
    /// Chromium `base::Feature`s the app's features turn on (process `chromium` in
    /// schemas/features/features.d, for example `cefTimerSlack`'s `TimerSlackMac`).
    var chromiumFeatures: [String] = []
    /// Chromium `base::Feature`s the app's features turn off (process `chromium`, off from any source:
    /// the channel default, the remote document, policy or `CMUX_DISABLE_FEATURES`). They go in one
    /// `disable-features` entry and leave the `enable-features` entry, also a feature cmux itself names
    /// there: disable wins, as in Chromium's `FeatureList::InitFromCommandLine` (base/feature_list.cc).
    var disabledChromiumFeatures: [String] = []
    /// The default-off feature `chromiumSpareAfterFirstTab`: pass the fork's spare renderer policy
    /// (`spareRendererAfterFirstTab`).
    var spareAfterFirstTab = false
    /// Host mode shows `<input type=color>` in cmux (``ChromiumHostChoosers``): the renderer asks the browser
    /// for a chooser (fork API 31's Blink feature), so the fork's handler gets it, not Blink's own popup.
    var embedderColorChooser = false
    /// Chromium's own spare renderer is off (``spareRendererFeature`` in the one `disable-features`
    /// entry): the default-off feature `chromiumOneSpareRenderer` while the spare windows' placeholders
    /// hold a renderer, which is then the one spare (``CEFSpareWindow/keepsChromiumSpare``).
    var chromiumSpareOff = false
    /// Development builds share one ad hoc identity per tag; the real
    /// keychain would prompt for "Chromium Safe Storage" on every rebuild.
    /// `CMUX_NEXT_BENCH_REAL_KEYCHAIN=1` turns it off in Debug and bench builds of a development
    /// bundle: chromium-host-bench.py `--modes tcc` measures the real OSCrypt key read.
    var useMockKeychain: Bool
    /// Unpacked extension directories (development and verification only).
    var loadExtensions: [String]
    /// Extensions the app bundle ships (`CEFBuiltInExtensions`); they do not
    /// turn on the extensions developer mode.
    var builtInExtensions: [String] = []
    /// The default-off feature `chromiumAdBlockerAtFirstTab` on a fork with `cmux_ext_load_command_line_async`:
    /// ``builtInExtensions`` stay off `--load-extension` and load into each persistent profile right
    /// before its first browser tab (``CEFBuiltInExtensionLoads``), so Home with no browser tab runs no
    /// extension background page.
    var builtInExtensionsAtFirstTab = false
    /// Unpacked extensions stay enabled without developer mode: true while
    /// the built-in uBlock Origin loads or the person has their own unpacked
    /// copy of it (`CEFBuiltInExtensions.Plan`).
    var keepsUnpackedEnabled = false
    /// Extra Chromium switches for diagnosis (development bundles only), for
    /// example `show-browser-frame-regions` or `enable-ui-devtools=9223`.
    var extraSwitches: [String] = []
    /// Switches a bench run sets (`CMUX_NEXT_BENCH_CEF_SWITCHES`, development and bench bundles of a
    /// Debug or bench build only): only the names in ``benchSwitchNames``.
    var benchSwitches: [String] = []
    /// The agent site's main-frame cap from the default-off feature `agentPageRendererSharing` (its
    /// `mainFrames` param); nil while the feature is off.
    var agentPageMainFrameCap: Int?
    /// PL-memory's cmux page sharing table (``pageSchemeProcessPerSite``): each cmux page host that may
    /// share a renderer, with its cap (``CEFPageSchemes/siteCaps(_:)``). Empty: no switch.
    var pageSiteCaps: [PageSiteCap] = []
    /// Chrome's memory caps on a shared renderer, from the app's budget (``CEFSharedRendererMemoryCaps``). Nil:
    /// no switch, Chromium keeps Chrome's values.
    var sharedRendererMemoryCaps: CEFSharedRendererMemoryCaps?

    /// The switches a bench run may set: the pair Web Page Replay needs to serve a recorded archive
    /// (catapult web_page_replay_go/README.md: `--host-resolver-rules` maps every host to the replay
    /// server, `--ignore-certificate-errors-spki-list` trusts only its certificate), and the shared-renderer
    /// memory caps (``CEFSharedRendererMemoryCaps``), so bench_renderer_sharing can grow a page past a cap
    /// the code Release runs reads; a bench value replaces the budget's. Any other switch would make a bench
    /// build measure an engine Release never runs, so it is dropped.
    static let benchSwitchNames: Set<String> = [
        "host-resolver-rules", "ignore-certificate-errors-spki-list",
        CEFSharedRendererMemoryCaps.mainFrameSwitch, CEFSharedRendererMemoryCaps.subframeSwitch,
    ]
    /// Chromium's AsyncLiveResize (below fork API 27): off only for the Debug Settings "Synced live"
    /// drag resize (`BrowserDragResize.synced`), which lets Chromium hold a frame for the page again.
    var asyncLiveResize = true

    /// The longest one Chromium pump pass runs before it returns to the main run loop: a quarter
    /// of a 120 Hz frame, so the app's own frame work and the display link fit beside a pass. It is
    /// the cap: with feature `cefPumpFrameDeadline` and a fork that takes a slice per call, each pass
    /// runs only to the frame's commit deadline (``CEFPumpFrameDeadline``).
    static let pumpTimeSliceMicroseconds = 2_000

    /// The first fork API with the resize-sync call (``CEFForkFeatures/resizeSyncForkAPI``; the same
    /// version as `CEFLayerHosting.resizeSyncForkAPI`, which is main-actor isolated).
    static let resizeSyncForkAPI = CEFForkFeatures.resizeSyncForkAPI

    /// What the fork offers for the resize switch. The resize capability reads the API number only.
    private var forkFeatures: CEFForkFeatures {
        CEFForkFeatures(forkAPIVersion: forkAPIVersion, shimHasRendererPaths: rendererPaths)
    }

    /// The fork's switch that keeps main-frame process reuse's DevTools check per renderer
    /// (`CEFForkFeatures.rendererPathsForkAPI`, fork API 29): Chromium's
    /// content/browser/renderer_host/render_frame_host_manager.cc asks
    /// `DevToolsAgentHost::WasEverAttachedToAnyFrame` for the whole browser instead.
    static let processReusePerRendererDevTools = "cmux-process-reuse-per-renderer-devtools"
    /// The fork's Blink runtime feature that sends `<input type=color>` to the embedder's color chooser
    /// handler (include/cef_cmux.h, `cmux_set_color_chooser_handler`; Android's ColorChooserFactory path).
    static let embedderColorChooserArgument = "enable-blink-features=CmuxEmbedderColorChooser"

    var arguments: [String] {
        var result: [String] = []
        if forkAPIVersion >= 1 {
            // One Chromium Browser per pane host, Chromium's own UI hidden
            // (include/cef_cmux.h in the fork).
            result.append("cmux-tabbed-windows")
        }
        // Non-official builds otherwise enable the field trial testing config
        // (features that need helpers cmux does not ship).
        result.append("disable-field-trial-config")
        // Web notifications must not make CEF's Alerts helper request a
        // separate macOS notification authorization. DesktopNotifier owns the
        // one app-level authorization request when cmux posts a banner.
        result.append("disable-notifications")
        // Chromium's periodic call-stack profiler runs in the browser process (the
        // app) and suspends its threads at 10 Hz while it collects. Its profiles go
        // to UMA, which cmux does not upload; in some idle sessions it raised the
        // app's energy with 20 hidden tabs from about 0.24 to 4 mW (msg 2654).
        result.append("disable-stack-profiler")
        // Chromium's UI thread is the app's main thread (external message pump): one
        // `CefDoMessageLoopWork` pass ran ready work for up to CEF's 10 ms slice, longer than a
        // 120 Hz frame, so a pass during a split or a divider drag dropped the frame. The fork
        // (cef-cmux 066b083f, `--cmux-pump-time-slice-us`) ends a pass after this slice and asks for
        // "now" again when work is left, so display frames run between passes. Older forks ignore it.
        result.append("cmux-pump-time-slice-us=\(Self.pumpTimeSliceMicroseconds)")
        result.append(contentsOf: Self.chromePromptOffSwitches)
        result.append(Self.syncOffSwitch)
        // One entry each: the shim merges them into CEF's own lists (CEFShim/src/command_line_switches.h),
        // and Chromium passes the lists to every child process.
        result.append("enable-features=" + enabledFeatures.joined(separator: ","))
        result.append("disable-features=" + disabledFeatures.joined(separator: ","))
        // Chrome shares a renderer between at most 2 main frames of one site below its process
        // limit (kProcessPerSiteUpToMainFrameThreshold), but Chromium 154 turns that off for the
        // whole process once any frame ever had a DevTools agent (RenderFrameHostManager,
        // WasEverAttachedToAnyFrame), which an agent's CDP session does. The fork's switch keeps
        // the check per renderer only (a renderer with a DevTools agent is never shared), so one
        // agent does not end sharing everywhere (fork API 29; tab-lifecycle.md "Renderer sharing").
        if rendererPaths { result.append(Self.processReusePerRendererDevTools) }
        // Chrome gives every NTP one renderer (ChromeContentBrowserClient::ShouldUseProcessPerSite) and
        // sends top-chrome WebUI to a live renderer of its lock (ShouldTryToUseExistingProcessHost). The
        // fork reads this table the second way, so a cap holds: a listed cmux page host joins a live
        // renderer of its own host (with page groups registered, of its group) while that renderer has
        // fewer main frames than the cap and no DevTools agent (cmux_page_groups.cc).
        // A host with no entry keeps Chromium's process per origin. Without the renderer paths every
        // page talks through DevTools and the fork shares none, so the switch needs them too.
        let siteCaps = pageSiteTable
        if rendererPaths, forkAPIVersion >= Self.pageSiteSharingForkAPI, !siteCaps.isEmpty {
            result.append(Self.pageSchemeProcessPerSiteArgument(siteCaps))
        }
        if spareAfterFirstTab { result.append(Self.spareRendererAfterFirstTab) }
        // Chrome's memory caps on a shared renderer, from the app's budget: a main frame joins a same-site
        // renderer (and, in the fork, a cmux page a live renderer of the table above) only while the renderer's
        // footprint plus its estimate for one more main frame stays under the cap (render_process_host_impl.cc
        // HasEnoughMemoryForAnotherMainFrame). A bench switch of the same name sets it instead.
        result.append(contentsOf: sharedRendererMemoryArguments)
        if embedderColorChooser { result.append(Self.embedderColorChooserArgument) }
        // Never pass a feature-list switch expecting it to replace CEF's own
        // list: the shim merges disable-features/enable-features into it
        // (CEFShim/src/command_line_switches.h). Chromium's code-sign clone
        // (MacAppCodeSignClone) stays on: it protects running helpers when an
        // update replaces the bundle, and its --type=code-sign-clone-cleanup
        // helper exits by itself about 1 s after the app (cx-dj33).
        if useMockKeychain {
            result.append("use-mock-keychain")
        }
        let loaded = (builtInExtensionsAtFirstTab ? [] : builtInExtensions) + loadExtensions
        if !loaded.isEmpty {
            result.append("load-extension=" + loaded.joined(separator: ","))
        }
        // Chromium records a --load-extension copy as unpacked and disables
        // unpacked extensions while developer mode is off
        // (DISABLE_UNSUPPORTED_DEVELOPER_EXTENSION). That policy is off while
        // the built-in uBlock Origin loads or the person's own unpacked copy
        // exists; with the setting off, it stays on and disables the old
        // built-in entry Chromium keeps in the profile. The shim merges this
        // into CEF's list.
        if keepsUnpackedEnabled { result.append("disable-features=ExtensionDisableUnsupportedDeveloper") }
        result.append(contentsOf: benchSwitches)
        result.append(contentsOf: extraSwitches)
        return result
    }

    /// The Chromium `base::Feature`s of the one `enable-features` entry, each once.
    var enabledFeatures: [String] {
        var features: [String] = []
        // The fork resizes a page's child window with its pane, and Chromium 154 then holds the
        // app's Core Animation commit (its CATransactionCoordinator pre-commit handler, on our main
        // thread) until it has a frame at the new size, or for up to 500 ms: each frame of a split
        // or close that resized a page waited for that page's relayout and raster. AsyncLiveResize
        // skips the wait in NativeWidgetNSWindowBridge::UpdateWindowGeometry; a page window is never
        // in a live resize of its own, so the async live-resize path it also turns on never runs.
        // From fork API 27 a resize with no deadline skips Synchronize (no pre-commit wait, no GPU
        // CA transaction, no 50 ms post-commit wait), and a layer-hosted page waits up to the
        // deadline CEFLayerHosting sets, so AsyncLiveResize would only lose that sync. A fork without
        // that skip keeps AsyncLiveResize: dropping it would put both waits back on the main thread.
        // Debug Settings "Synced live" drag resize (`asyncLiveResize` false) leaves it off, so Chromium
        // holds a frame for the page again.
        if asyncLiveResize, !forkFeatures.resizeWaitsOnlyForDeadline { features.append("AsyncLiveResize") }
        // The app's Chromium features come last, for example `cefTimerSlack` (default off):
        // `kTimerSlackMac` (base/message_loop/message_pump_apple.mm, message_pump_kqueue.cc) gives each
        // CFRunLoop and kqueue pump's delayed timer the task's leeway. It changes renderer, GPU and
        // utility processes and the browser's non-UI threads only: the UI thread's MessagePumpExternal
        // arms no base timer, and the app's deadline queue gets the leeway from the fork's absolute
        // run times.
        // A feature the app turns off leaves this entry, so the two lists never name one feature.
        let named = [Self.chromePromptOffFeature] + Self.wakeUpAlignmentFeatures + Self.idleSourceOffFeatures
        let disabled = Set(disabledFeatures)
        for feature in named + chromiumFeatures
        where !features.contains(feature) && !disabled.contains(Self.featureName(of: feature)) {
            features.append(feature)
        }
        return features
    }

    /// The Chromium `base::Feature`s of the one `disable-features` entry, each once: the idle services
    /// cmux does not use (``idleServiceOffFeatures``), then the app's off features
    /// (``disabledChromiumFeatures``), then Chromium's spare renderer while ``chromiumSpareOff``
    /// (``spareRendererFeature``).
    var disabledFeatures: [String] {
        var features: [String] = []
        let spareOff = chromiumSpareOff ? [Self.spareRendererFeature] : []
        for feature in Self.idleServiceOffFeatures + disabledChromiumFeatures + spareOff
        where !features.contains(feature) {
            features.append(feature)
        }
        return features
    }

    /// The feature an `enable-features` entry names: `IPH_DemoMode:chosen_feature/IPH_Dummy` is
    /// `IPH_DemoMode` (the `Name<Study:param/value` syntax `FeatureList::ParseEnableFeatures` reads,
    /// base/feature_list.cc; a leading `*` is the default-state marker).
    static func featureName(of entry: String) -> String {
        String(entry.drop { $0 == "*" }.prefix { $0 != "<" && $0 != ":" })
    }

    /// Chromium's wake-up alignment. Both are `FEATURE_DISABLED_BY_DEFAULT`; Chrome turns them on
    /// only through field trials, and `disable-field-trial-config` leaves them off in cmux:
    /// - `AlignWakeUps` (base/task/task_features.h, .cc): `MessagePump::AdjustDelayedRunTime`
    ///   (base/message_loop/message_pump.cc) snaps a delayed wake-up to the next `kDefaultLeeway`
    ///   (8 ms) tick of `TimeTicks()`, never past the task's latest time (a precise task keeps
    ///   its time), so the threads of every process wake together. The sequence manager asks the
    ///   pump for each delayed wake-up (thread_controller_with_message_pump_impl.cc).
    /// - `BatterySaverModeAlignWakeUps` (content/public/common/content_features.cc): in battery
    ///   saver, `ChildThreadImpl::SetBatterySaverMode` (content/child/child_thread_impl.cc) widens
    ///   the grid to 32 ms in each child process. It does nothing until saver mode is set.
    ///
    /// The app's Chromium UI thread runs CEF's `MessagePumpExternal` (fork
    /// libcef/browser/browser_message_loop.cc, made by `MessagePumpFactoryForUI` when
    /// `external_message_pump` is set). It derives from `base::MessagePumpForUI`, which is plain
    /// `base::MessagePump` on Mac (base/message_loop/message_pump_for_ui.h), and keeps the base
    /// `AdjustDelayedRunTime`, so the UI thread snaps too. The browser's other threads and every
    /// child process use Chromium's own pumps (message_pump_apple.mm, message_pump_kqueue.cc).
    ///
    /// `TimerSlackMac` is not in this list: with it on, those pumps return `earliest_time` from
    /// `AdjustDelayedRunTime` and give the kernel the leeway instead of the snap, which the UI
    /// thread gets only from the absolute run times of p14-energy-046. It stays the default-off
    /// feature `cefTimerSlack` (``chromiumFeatures``).
    static let wakeUpAlignmentFeatures = ["AlignWakeUps", "BatterySaverModeAlignWakeUps"]

    /// Chromium features that quiet an idle source (Q8, p14-energy-042..044: a posting location at or above
    /// 0.02 tasks/s in an idle session), one location each. Chromium 154.0.8037 sources:
    /// - `PartitionAllocAdaptiveMemoryReclaimInterval` (base/allocator/partition_alloc_features.cc,
    ///   `FEATURE_DISABLED_BY_DEFAULT`, so `disable-field-trial-config` leaves it off). Location
    ///   `MemoryReclaimerSupport::Run` (base/allocator/partition_alloc_support.cc): every process with
    ///   PartitionAlloc as malloc (all of them on Mac) decommits empty slot spans on its main thread every
    ///   4 s (`MemoryReclaimer::GetRecommendedReclaimIntervalInMicroseconds`, partition_alloc/memory_reclaimer.cc),
    ///   0.25/s each in the app's CrBrowserMain, the GPU and utility processes, and every renderer while it
    ///   is foreground. With the feature the interval starts at 8 s and doubles up to 1 min while a reclaim
    ///   decommits under 100 KiB (0.017/s at idle); above 200 KiB it halves back toward 4 s
    ///   (`MemoryReclaimer::ComputeNextReclaimInterval`), so a process with memory to give back reclaims as
    ///   often as before. Nothing visible depends on the cadence.
    static let idleSourceOffFeatures = ["PartitionAllocAdaptiveMemoryReclaimInterval"]

    /// The first fork API whose `cmux-page-scheme-process-per-site` reads a per-site cap table
    /// (``CEFForkFeatures/pageSiteSharingForkAPI``, the fork train's number). API 29 has only
    /// `cmux-process-reuse-per-renderer-devtools`.
    static let pageSiteSharingForkAPI: Int32 = CEFForkFeatures.pageSiteSharingForkAPI

    /// ``sharedRendererMemoryCaps``' switches, less those ``benchSwitches`` set.
    var sharedRendererMemoryArguments: [String] {
        let benchNames = Set(benchSwitches.map(Self.switchName(of:)))
        return (sharedRendererMemoryCaps?.arguments ?? []).filter { !benchNames.contains(Self.switchName(of: $0)) }
    }

    /// The name of a `name=value` switch.
    static func switchName(of entry: String) -> String {
        String(entry.prefix { $0 != "=" })
    }

    /// The one cmux page sharing table the switch carries: ``pageSiteCaps``, with the agent site's entry
    /// set to ``agentPageMainFrameCap`` when that feature gives one.
    var pageSiteTable: [PageSiteCap] {
        guard let agentCap = agentPageMainFrameCap else { return pageSiteCaps }
        let others = pageSiteCaps.filter { $0.site != Self.agentPageSite }
        return (others + [PageSiteCap(site: Self.agentPageSite, mainFrames: agentCap)]).sorted { $0.site < $1.site }
    }

    /// PL-memory's switch for the cmux page scheme (p07-memory 049: ShouldUseProcessPerSite in the fork).
    /// Its value lists the cmux-page sites that share a renderer, each with the most main frames one
    /// renderer takes; a cmux-page site with no entry keeps Chrome's process reuse.
    static let pageSchemeProcessPerSite = "cmux-page-scheme-process-per-site"

    /// The New Tab and every agent chat are this one site (`cmux-page://cmux.agent`), shared the way Chrome
    /// shares one process for every NTP (ChromeContentBrowserClient::ShouldUseProcessPerSite).
    static let agentPageSite = "cmux.agent"

    /// One cmux-page site and its main-frame cap. Chrome has one cap for every site, the
    /// ProcessPerSiteMainFrameThreshold param (2) of kProcessPerSiteUpToMainFrameThreshold
    /// (content/public/common/content_features.cc); the agent site's 8 bounds how many pages one renderer
    /// crash or one streaming chat reaches (plans/cmux-next/chrome-parity/p13-webui.md, risk 4).
    struct PageSiteCap: Equatable, Sendable {
        var site: String
        var mainFrames: Int
    }

    /// `cmux-page-scheme-process-per-site=<site>:<mainFrames>[,<site>:<mainFrames>...]`.
    static func pageSchemeProcessPerSiteArgument(_ caps: [PageSiteCap]) -> String {
        pageSchemeProcessPerSite + "=" + caps.map { "\($0.site):\($0.mainFrames)" }.joined(separator: ",")
    }

    /// Chrome's own promotions, tips and first-run prompts are for Google
    /// Chrome, not for a browser pane in cmux ("Split view makes it easier to
    /// multitask", "Make Chrome your default browser", "What's new"). These
    /// switches turn every such surface off (cx-lqitn; Chromium 154 sources
    /// named below):
    /// - `no-first-run`: no first-run experience, no What's New page
    ///   (whats_new_util.cc), no default-browser, session-restore or
    ///   pin-to-taskbar startup infobars (startup/infobar_utils.cc), and
    ///   UserEducationService gets allows_promos=false
    ///   (UserEducationServiceFactory::ProfileAllowsUserEducation): no
    ///   in-product help bubbles, tutorials, "New" badges or New Tab Page
    ///   promos. This is the state Chrome's own automation runs in.
    /// - `no-default-browser-check`: the default-browser prompt, also
    ///   without the first-run switch (defense in depth; the macOS updater
    ///   infobar it also gates is Google Chrome only).
    /// - `disable-search-engine-choice-screen`: the search engine choice
    ///   dialog (search_engine_choice_service.cc). Defense in depth: a build
    ///   without Chrome branding makes no dialog service unless
    ///   `force-search-engine-choice-screen` is set.
    /// - `IPH_DemoMode:chosen_feature/IPH_Dummy` (``chromePromptOffFeature``,
    ///   in the one `enable-features` entry, ``enabledFeatures``): the
    ///   feature-engagement tracker runs in demo mode with only IPH_Dummy
    ///   valid (Tracker::Create, CreateDemoModeTracker), and nothing triggers
    ///   IPH_Dummy. Code that asks the tracker directly, not through
    ///   UserEducationService, then gets "no" too: the bookmark-bubble
    ///   sign-in promo, "Get Chrome on your phone" promos, price tracking,
    ///   the performance intervention dialog and the downloads page promo.
    ///   The demo tracker keeps its events in memory, so it writes no
    ///   feature-engagement database to the profile. Development extra
    ///   switches must not name IPH_DemoMode: a second enable entry loses
    ///   (the first override wins) and its duplicate parameters fail a
    ///   DCHECK, and `disable-features=IPH_DemoMode` turns this off.
    /// Not switched here because the build already turns them off: surveys
    /// (HaTS needs metrics consent), sign-in and sync promos (no Google OAuth
    /// client in this build, so DICE is off), the outdated-build bubble
    /// (Google Chrome builds only) and the Privacy Sandbox ad privacy notice
    /// (removed in Chromium 154, kPrivacySandboxAdPrivacyUxDeprecation).
    static let chromePromptOffSwitches = [
        "no-first-run",
        "no-default-browser-check",
        "disable-search-engine-choice-screen",
    ]

    static let chromePromptOffFeature = "IPH_DemoMode:chosen_feature/IPH_Dummy"

    /// Chrome runtime services that work with no page shown and that cmux does not use
    /// (the census, and what stays on and why, is perf-lead.md "Chrome runtime idle services"): the
    /// ``syncOffSwitch`` and these features in the one `disable-features` entry (``disabledFeatures``).
    /// Chromium 154 sources are named on each constant. Safe Browsing, the component updater
    /// (Widevine CDM, CRLSet), network time and Cast stay on.
    static let idleServiceOffFeatures = hangWatcherOffFeatures + [optimizationHintsOffFeature]

    /// `disable-sync` (components/sync/base/command_line_switches.h, kDisableSync):
    /// SyncServiceFactory::GetForProfile returns null, so the profile makes no SyncServiceImpl, sync
    /// engine or sync invalidations listener. cmux has no Google sign-in (no OAuth client, DICE off)
    /// and owns the bookmarks tree; password code reads a null sync service as "not syncing"
    /// (password_sync_util.cc GetPasswordSyncState), and the fork's generation switch needs no sync.
    static let syncOffSwitch = "disable-sync"

    /// `EnableHangWatcher` and `EnableHangWatcherOnGpuProcess` (base/threading/hang_watcher.cc): a
    /// HangWatcher thread in each Chromium process (the app is the browser process) wakes every 10 s
    /// (kHangWatcherMonitoringPeriod) and reports a hung thread with DumpWithoutCrashing. Chromium
    /// turns it on only "where the generated data is used"; cmux ships no crash_reporter.cfg, so the
    /// dumps go nowhere. The GPU process reads its own feature (HangWatcher::InitializeOnMainThread).
    static let hangWatcherOffFeatures = ["EnableHangWatcher", "EnableHangWatcherOnGpuProcess"]

    /// `OptimizationHints` (components/optimization_guide/core/optimization_guide_features.cc): with it
    /// off, the Optimization Hints component is not registered with the component updater
    /// (optimization_hints_component_installer.cc RegisterOptimizationHintsComponent) and the hints
    /// manager has no hints to fetch or refresh. No cmux feature reads the hints; Chrome's automation
    /// launchers (Puppeteer, chrome-launcher) turn it off too. `OptimizationTargetPrediction` stays:
    /// Safe Browsing's client-side detection model arrives through the optimization guide's model
    /// provider (client_side_detection_service.cc).
    static let optimizationHintsOffFeature = "OptimizationHints"

    /// Switches for this process. `CMUX_NEXT_CEF_LOAD_EXTENSIONS` is a
    /// colon-separated list of unpacked extension directories.
    /// `CMUX_NEXT_CEF_EXTRA_SWITCHES` is a colon-separated list of switches
    /// (leading dashes optional). Debug builds of development bundles only;
    /// see plans/cmux-next/browser.md ("Chromium diagnostics").
    /// `CMUX_NEXT_BENCH_CEF_SWITCHES` is a newline-separated list of `name=value`
    /// switches (``benchSwitches(_:)``); Debug and bench builds of development
    /// bundles read it.
    static func current(
        forkAPIVersion: Int32,
        rendererPaths: Bool = false,
        chromiumFeatures: [String] = [],
        disabledChromiumFeatures: [String] = [],
        spareAfterFirstTab: Bool = false,
        embedderColorChooser: Bool = false,
        chromiumSpareOff: Bool = false,
        bundleIdentifier: String?,
        environment: [String: String],
        builtInExtensions: [String] = [],
        builtInExtensionsAtFirstTab: Bool = false,
        keepsUnpackedEnabled: Bool = false,
        agentPageMainFrameCap: Int? = nil,
        pageSiteCaps: [PageSiteCap] = [],
        sharedRendererMemoryCaps: CEFSharedRendererMemoryCaps? = nil,
        asyncLiveResize: Bool = true
    ) -> CEFSwitches {
        let bundle = bundleIdentifier ?? ""
        let developmentBundle = bundle.contains(".debug") || bundle.hasSuffix(".dev")
        let extensions = (environment["CMUX_NEXT_CEF_LOAD_EXTENSIONS"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
        #if DEBUG
        let dev = developmentBundle || environment["CMUX_MOCK_KEYCHAIN"] == "1"
        let extra = dev ? Self.extraSwitches(environment["CMUX_NEXT_CEF_EXTRA_SWITCHES"]) : []
        #else
        let extra: [String] = []
        #endif
        #if DEBUG || CMUX_BENCH_HOOKS
        let bench = developmentBundle ? Self.benchSwitches(environment["CMUX_NEXT_BENCH_CEF_SWITCHES"]) : []
        let benchRealKeychain = developmentBundle && environment["CMUX_NEXT_BENCH_REAL_KEYCHAIN"] == "1"
        #else
        let bench: [String] = []
        let benchRealKeychain = false
        #endif
        let mockKeychain = environment["CMUX_MOCK_KEYCHAIN"] == "1" || (developmentBundle && !benchRealKeychain)
        return CEFSwitches(
            forkAPIVersion: forkAPIVersion,
            rendererPaths: rendererPaths,
            chromiumFeatures: chromiumFeatures,
            disabledChromiumFeatures: disabledChromiumFeatures,
            spareAfterFirstTab: spareAfterFirstTab,
            embedderColorChooser: embedderColorChooser,
            chromiumSpareOff: chromiumSpareOff,
            useMockKeychain: mockKeychain,
            loadExtensions: extensions,
            builtInExtensions: builtInExtensions,
            builtInExtensionsAtFirstTab: builtInExtensionsAtFirstTab && !builtInExtensions.isEmpty,
            keepsUnpackedEnabled: keepsUnpackedEnabled,
            extraSwitches: extra,
            benchSwitches: bench,
            agentPageMainFrameCap: agentPageMainFrameCap,
            pageSiteCaps: pageSiteCaps,
            sharedRendererMemoryCaps: sharedRendererMemoryCaps,
            asyncLiveResize: asyncLiveResize
        )
    }

    static func extraSwitches(_ value: String?) -> [String] {
        (value ?? "")
            .split(separator: ":")
            .map { String($0.drop { $0 == "-" }) }
            .filter { !$0.isEmpty }
    }

    /// The allowed switches of `value`: one `name=value` per line (leading dashes optional, a
    /// value may hold colons and commas, as `MAP *:443 127.0.0.1:8081,EXCLUDE localhost` does).
    /// A line whose name is not in ``benchSwitchNames`` or that has no value is dropped.
    static func benchSwitches(_ value: String?) -> [String] {
        (value ?? "")
            .split(whereSeparator: \.isNewline)
            .map { String($0.drop { $0 == "-" }) }
            .filter { line in
                guard let equals = line.firstIndex(of: "="), line.index(after: equals) < line.endIndex else { return false }
                return benchSwitchNames.contains(String(line[..<equals]))
            }
    }
}
