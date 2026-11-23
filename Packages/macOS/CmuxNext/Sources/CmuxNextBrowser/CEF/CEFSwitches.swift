import Foundation

/// Browser-process command-line switches for the embedded Chromium.
nonisolated struct CEFSwitches: Equatable, Sendable {
    /// `cmux_cef_api_version()`; 0 for stock CEF.
    var forkAPIVersion: Int32
    /// The fork and shim have the renderer paths (`CEFForkFeatures.rendererPaths`): no tab keeps a
    /// DevTools session, so the per-renderer reuse switch applies.
    var rendererPaths = false
    /// Development builds share one ad hoc identity per tag; the real
    /// keychain would prompt on every rebuild. Every other build keeps
    /// Chromium's key in cmux's own item (`CEFKeychainItem`), and falls back to
    /// this when the fork does not take that item (`CEFRuntime.applyKeychainItem`).
    var useMockKeychain: Bool
    /// Unpacked extension directories (development and verification only).
    var loadExtensions: [String]
    /// Extensions the app bundle ships (`CEFBuiltInExtensions`); they do not
    /// turn on the extensions developer mode.
    var builtInExtensions: [String] = []
    /// Unpacked extensions stay enabled without developer mode: true while
    /// the built-in uBlock Origin loads or the person has their own unpacked
    /// copy of it (`CEFBuiltInExtensions.Plan`).
    var keepsUnpackedEnabled = false
    /// Extra Chromium switches for diagnosis (development bundles only), for
    /// example `show-browser-frame-regions` or `enable-ui-devtools=9223`.
    var extraSwitches: [String] = []
    /// Chromium's AsyncLiveResize (below fork API 27): off only for the Debug Settings "Synced live"
    /// drag resize (a Synced live drag resize, removed 2026-11-06), which lets Chromium hold a frame for the page again.
    var asyncLiveResize = true
    /// Chromium presents a page's frame as soon as it has drawn it (`CEFFramePacing`), off by
    /// default: the Debug Settings read, taken at launch because Chromium reads its command line once.
    var noFrameRateLimit = false

    /// The profile Chromium opens at startup (`profile-directory`), a directory name under the root
    /// cache: the default cmux profile's (`CEFProfileStorage.initialProfileDirectory`). Nil leaves
    /// Chromium's own choice (its last-used profile, `Default` on a first launch).
    var initialProfileDirectory: String?
    /// The staged-update Chromium pre-warm keeps Chromium's code-sign clone enabled so Sparkle can replace the
    /// running bundle without leaving its helpers on the old executable. Ordinary app launches leave it off.
    var keepsCodeSignClone = false

    /// The longest one Chromium pump pass runs before it returns to the main run loop: a quarter
    /// of a 120 Hz frame, so the app's own frame work and the display link fit beside a pass.
    static let pumpTimeSliceMicroseconds = 2_000

    /// The first fork API with the resize-sync call: the fork waits for a page's frame at a new
    /// size only up to a deadline the app sets (the same version as `CEFLayerHosting.resizeSyncForkAPI`,
    /// which is main-actor isolated; this value is read where the switches are worked out, off it).
    static let resizeSyncForkAPI: Int32 = 27

    /// Pages draw overlay scrollbars whatever the system's scroller style. Chromium's default
    /// (`OverlayScrollbar` mode `device`) follows `NSScroller.preferredScrollerStyle`, which flips
    /// whenever a mouse comes or goes, Universal Control's shared mouse included: a classic scrollbar
    /// took its width from every scrolling page and the page reflowed on each flip (Leo 2026-11-15:
    /// "our chromium browser also has a bt of layout shif tfor some reason idk why"). Mode `overlay`
    /// forces them (ui/native_theme/features/native_theme_features.cc, `ShouldUseOverlayScrollbar`),
    /// the native views' SCROLLBARS-THIN rule (SystemScrollers.nativeStyle). The shim merges it
    /// into CEF's feature list.
    static let overlayScrollbars = "enable-features=OverlayScrollbar:mode/overlay"

    /// Renderers start V8's young generation at 32 MB a semi-space instead of growing it from 1 MB. A streaming
    /// chat makes short-lived garbage on every token, and a long chat's renderer scavenged far more often than a
    /// short one's (309 against 92 over one replay, median 30 ms against 14). On the paired transcript replay
    /// (god chat, 34,641 rows, against a small one; 8 rounds on the build fleet, CPU clock) the god / small p95
    /// went from 1.41 to 1.07 for thought updates and from 1.49 to 1.37 for tokens, and the god chat's thought
    /// p95 from 8.37 to 5.64 ms. The renderer's memory did not grow: 153 MB with one chat and 472 MB with ten,
    /// against 154 and 478 MB without it (chat-pages-memory, 3 runs a side). Leo, 2026-11-12: a god chat shows
    /// "no perceivable difference" from a small one (within 1.2x).
    static let youngGeneration = "js-flags=--min-semi-space-size=32"

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
        // Web notifications must not make CEF's Alerts helper request a separate macOS
        // notification authorization: DesktopNotifier owns the one app-level request, made when
        // cmux posts a banner. Chromium's macOS notification bridge, made for the profile at
        // startup while SystemNotifications is on, asked macOS for authorization for the app and
        // its Alerts helper on the first launch, with no action of the person
        // (LAUNCH-NO-TCC-PROMPTS). Off, Chromium makes no bridge.
        //
        // Never add `disable-notifications` here: it takes `Notification` and `PushManager` out
        // of every page, which no desktop Chrome does, and bot checks read that as automation.
        // Akamai Bot Manager then served its challenge page again and again (godaddy.com reloaded
        // about twice per second, then "Access Denied"; Chrome with the two interfaces deleted
        // does the same). Pages keep the interfaces and read the permission as `default`, also
        // after they ask (the shim ends the request unanswered, permission_prompt_policy.h),
        // so no web notification is ever shown.
        result.append("disable-features=SystemNotifications")
        // Chromium counts prompts that end unanswered and blocks the site for a week after four
        // (its embargo). No switch or feature turns that count off (permission_decision_auto_blocker.cc),
        // so the shim clears the site's own count before it ends a request (shim_permissions.mm).
        // Chromium's periodic call-stack profiler runs in the browser process (the
        // app) and suspends its threads at 10 Hz while it collects. Its profiles go
        // to UMA, which cmux does not upload; in some idle sessions it raised the
        // app's energy with 20 hidden tabs from about 0.24 to 4 mW (msg 2654).
        result.append("disable-stack-profiler")
        result.append(Self.youngGeneration)
        // A page draws when it has a frame, not when the display asks (`CEFFramePacing`): off by
        // default, since it also lets an animating page draw frames the display never shows.
        if noFrameRateLimit { result.append(contentsOf: CEFFramePacing.switches) }
        result.append(Self.overlayScrollbars)
        // Chromium's UI thread is the app's main thread (external message pump): one
        // `CefDoMessageLoopWork` pass ran ready work for up to CEF's 10 ms slice, longer than a
        // 120 Hz frame, so a pass during a split or a divider drag dropped the frame. The fork
        // (cef-cmux 066b083f, `--cmux-pump-time-slice-us`) ends a pass after this slice and asks for
        // "now" again when work is left, so display frames run between passes. Older forks ignore it.
        result.append("cmux-pump-time-slice-us=\(Self.pumpTimeSliceMicroseconds)")
        // The fork resizes a page's child window with its pane, and Chromium 154 then holds the
        // app's Core Animation commit (its CATransactionCoordinator pre-commit handler, on our main
        // thread) until it has a frame at the new size, or for up to 500 ms: each frame of a split
        // or close that resized a page waited for that page's relayout and raster. AsyncLiveResize
        // skips the wait in NativeWidgetNSWindowBridge::UpdateWindowGeometry; a page window is never
        // in a live resize of its own, so the async live-resize path it also turns on never runs.
        // From fork API 27 the fork's own default is no wait, and a layer-hosted page waits up to
        // the deadline CEFLayerHosting sets, so AsyncLiveResize would only lose that sync.
        if forkAPIVersion < Self.resizeSyncForkAPI, asyncLiveResize { result.append("enable-features=AsyncLiveResize") }
        result.append(contentsOf: Self.chromePromptOffSwitches)
        // Chrome shares a renderer between at most 2 main frames of one site below its process
        // limit (kProcessPerSiteUpToMainFrameThreshold), but Chromium 154 turns that off for the
        // whole process once any frame ever had a DevTools agent (RenderFrameHostManager,
        // WasEverAttachedToAnyFrame), which an agent's CDP session does. The fork's switch keeps
        // the check per renderer only (a renderer with a DevTools agent is never shared), so one
        // agent does not end sharing everywhere (fork API 29; tab-lifecycle.md "Renderer sharing").
        if rendererPaths { result.append(Self.processReusePerRendererDevTools) }
        // Every agent chat is the same first-party page (cmux-page://cmux.agent/), and Chromium's
        // process-per-site-instance gave each its own renderer: 100 idle chats held 107 renderers,
        // 17.5 GB of footprint and 30% CPU. The same-site main-frame sharing above never applies to
        // these pages (threshold 8 changed nothing). The fork gives the named schemes one renderer
        // per site, as Chrome gives its NTP (process-per-site for all sites in the same bench: 6
        // renderers, 6.6 GB, 7.3%); web pages keep Chrome's model. Older forks ignore the switch.
        result.append(Self.processPerSitePageSchemes)
        // One renderer per site put every chat in one renderer: one renderer crash or out-of-memory
        // kill reloaded every open chat (Leo, 2026-11-14: "separate the health of the overall process
        // from the falliability of crash prone bits"). The fork (cmux_process_per_site_main_frame_cap)
        // puts a page in the oldest renderer of its site that holds fewer than this many pages, or a
        // new one, and keeps it there, so a crash reloads at most that many chats. The cap keeps the
        // origin, so the pages' localStorage and every origin check stay as they are. Older forks
        // ignore the switch.
        result.append(Self.processPerSitePageCap)
        // Never pass a feature-list switch expecting it to replace CEF's own
        // list: the shim merges disable-features/enable-features into it
        // (CEFShim/src/command_line_switches.h).
        // Chromium's code-sign clone (MacAppCodeSignClone) is off. It hard-links
        // the main executable into a per-launch clone that a
        // --type=code-sign-clone-cleanup helper removes about 1 s after quit,
        // and macOS then held the next launch of that executable before its
        // first instruction (_dyld_start+0, no CPU, no reads): main_start 1447 ms
        // against 26 ms with the clone off (relaunch-restore, fronts=chat, 5
        // rounds each, one Mac). The clone guards helpers started after an update
        // replaced the bundle under a running app (cx-dj33); that cost is paid
        // on every relaunch after a Chromium session instead. The staged-update
        // pre-warm opts back in because it is the only Chromium process started
        // while a newer Sparkle bundle is staged.
        if !keepsCodeSignClone { result.append("disable-features=MacAppCodeSignClone") }
        if useMockKeychain {
            result.append("use-mock-keychain")
        }
        let loaded = builtInExtensions + loadExtensions
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
        // Chrome style opens one startup profile and makes it the global request context
        // (ChromeBrowserMainExtraPartsCef::PostProfileInit); CefSettings.cache_path does not choose
        // it. Without this switch that profile is `Default`, which no cmux tab uses, yet every regular
        // profile loads the --load-extension extensions: `Default` ran its own uBlock Origin
        // background page, an extension renderer of about 105 MB, from launch on (hq#7860).
        // Starting in the default cmux profile leaves one regular profile at idle. An
        // off-the-record context (an incognito window's store; the app opens one at launch)
        // derives from CEF's GetPrimaryUserProfile, which is this startup profile from fork
        // cmux.48 on (manaflow-ai/cef#32); before it was always `Default`, so `Default` loaded anyway.
        if let initialProfileDirectory, !initialProfileDirectory.isEmpty {
            result.append("profile-directory=" + initialProfileDirectory)
        }
        result.append(contentsOf: extraSwitches)
        return result
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
    /// - `enable-features=IPH_DemoMode:chosen_feature/IPH_Dummy`: the
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
    /// The fork's switch for per-renderer DevTools checks in main-frame process reuse (fork API 29).
    static let processReusePerRendererDevTools = "cmux-process-reuse-per-renderer-devtools"

    /// The fork's switch: one renderer per site for cmux's first-party page scheme
    /// (`PageDescriptor.scheme`; `cmux-process-per-site-schemes`, chrome_content_browser_client_cef.cc).
    static let processPerSitePageSchemes = "cmux-process-per-site-schemes=cmux-page"

    /// The most cmux pages one renderer holds: the size of the WebKit fallback's groups
    /// (`WebProcessGroups.pagesPerProcess`, `PageOverlayProcess`), so both engines lose at most 8
    /// pages to one process end. Each renderer past the first costs its base once per 8 pages.
    static let pagesPerRenderer = 8

    /// The fork's switch: at most ``pagesPerRenderer`` pages per renderer of a
    /// ``processPerSitePageSchemes`` site (fork patch cmux_process_per_site_main_frame_cap).
    static let processPerSitePageCap = "cmux-process-per-site-main-frame-cap=\(pagesPerRenderer)"

    static let chromePromptOffSwitches = [
        "no-first-run",
        "no-default-browser-check",
        "disable-search-engine-choice-screen",
        "enable-features=IPH_DemoMode:chosen_feature/IPH_Dummy",
    ]

    /// Switches for this process. `CMUX_NEXT_CEF_LOAD_EXTENSIONS` is a
    /// colon-separated list of unpacked extension directories.
    /// `CMUX_NEXT_CEF_EXTRA_SWITCHES` is a colon-separated list of switches
    /// (leading dashes optional). Debug builds of development bundles only;
    /// see plans/cmux-next/browser.md ("Chromium diagnostics").
    static func current(
        forkAPIVersion: Int32,
        rendererPaths: Bool = false,
        bundleIdentifier: String?,
        environment: [String: String],
        builtInExtensions: [String] = [],
        keepsUnpackedEnabled: Bool = false,
        asyncLiveResize: Bool = true,
        initialProfileDirectory: String? = nil,
        keepsCodeSignClone: Bool = false
    ) -> CEFSwitches {
        let bundle = bundleIdentifier ?? ""
        let dev = bundle.contains(".debug") || bundle.hasSuffix(".dev") || environment["CMUX_MOCK_KEYCHAIN"] == "1"
        #if DEBUG
        // Verification of the real keychain path (cmux's own item) in a development bundle.
        let realKeychain = environment["CMUX_NEXT_REAL_KEYCHAIN"] == "1"
        #else
        let realKeychain = false
        #endif
        let extensions = (environment["CMUX_NEXT_CEF_LOAD_EXTENSIONS"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
        #if DEBUG
        let extra = dev ? Self.extraSwitches(environment["CMUX_NEXT_CEF_EXTRA_SWITCHES"]) : []
        #else
        let extra: [String] = []
        #endif
        return CEFSwitches(
            forkAPIVersion: forkAPIVersion,
            rendererPaths: rendererPaths,
            useMockKeychain: dev && !realKeychain,
            loadExtensions: extensions,
            builtInExtensions: builtInExtensions,
            keepsUnpackedEnabled: keepsUnpackedEnabled,
            extraSwitches: extra,
            asyncLiveResize: asyncLiveResize,
            noFrameRateLimit: CEFFramePacing.noFrameRateLimit.settledValue,
            initialProfileDirectory: initialProfileDirectory,
            keepsCodeSignClone: keepsCodeSignClone
        )
    }

    static func extraSwitches(_ value: String?) -> [String] {
        (value ?? "")
            .split(separator: ":")
            .map { String($0.drop { $0 == "-" }) }
            .filter { !$0.isEmpty }
    }
}
