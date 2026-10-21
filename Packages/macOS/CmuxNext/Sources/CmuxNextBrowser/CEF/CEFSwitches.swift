import Foundation

/// Browser-process command-line switches for the embedded Chromium.
nonisolated struct CEFSwitches: Equatable, Sendable {
    /// `cmux_cef_api_version()`; 0 for stock CEF.
    var forkAPIVersion: Int32
    /// Development builds share one ad hoc identity per tag; the real
    /// keychain would prompt for "Chromium Safe Storage" on every rebuild.
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
        result.append(contentsOf: Self.chromePromptOffSwitches)
        // Never pass a feature-list switch expecting it to replace CEF's own
        // list: the shim merges disable-features/enable-features into it
        // (CEFShim/src/command_line_switches.h). Chromium's code-sign clone
        // (MacAppCodeSignClone) stays on: it protects running helpers when an
        // update replaces the bundle, and its --type=code-sign-clone-cleanup
        // helper exits by itself about 1 s after the app (cx-dj33).
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
        bundleIdentifier: String?,
        environment: [String: String],
        builtInExtensions: [String] = [],
        keepsUnpackedEnabled: Bool = false
    ) -> CEFSwitches {
        let bundle = bundleIdentifier ?? ""
        let dev = bundle.contains(".debug") || bundle.hasSuffix(".dev") || environment["CMUX_MOCK_KEYCHAIN"] == "1"
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
            useMockKeychain: dev,
            loadExtensions: extensions,
            builtInExtensions: builtInExtensions,
            keepsUnpackedEnabled: keepsUnpackedEnabled,
            extraSwitches: extra
        )
    }

    static func extraSwitches(_ value: String?) -> [String] {
        (value ?? "")
            .split(separator: ":")
            .map { String($0.drop { $0 == "-" }) }
            .filter { !$0.isEmpty }
    }
}
