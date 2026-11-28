#if canImport(CCmuxBackgroundReadyFFI)
import CCmuxBackgroundReadyFFI
#endif
import CmuxNextDaemonService

/// What `app.backgroundReady` means (Leo 2026-11-17, ask-b2b0f899c1: "how can we improve those? startup in
/// background maybe?"), asked of cmux-background-ready (Rust, through the app FFI): Swift gathers the inputs,
/// calls these and does the AppKit work, and decides nothing itself. A value the library answers that this
/// build does not know reads as the answer that changes nothing (exit, normal launch, keep windows).
///
/// TRANSITIONAL until CCmuxAppFFI is re-pinned past cmux-background-ready (with the pre-read functions of the
/// lane/background-ready-preread-rust PR, which stacks on #45813): a pinned release without its
/// header (`CCmuxBackgroundReadyFFI`) answers every question as the setting's `off` does, so nothing a
/// person sees or the app does changes.
nonisolated enum BackgroundReadyRules {
    /// `app.backgroundReady`'s value, as the library reads it.
    enum Mode: UInt8, Sendable {
        case off = 0, afterQuit = 1, afterQuitAndLogin = 2, warmAtLogin = 3
    }

    /// What a stay hides.
    enum HiddenPlan: UInt8, Sendable {
        /// Every window is ordered out and kept, with its content, and ordered in again at the next show.
        case keepWindows = 0
        /// Every window is closed as a person closes it; the next show reopens each.
        case closeWindows = 1
        /// No window is made (a login start); the next show runs the normal restore.
        case nativeOnly = 2
    }

    /// What a launch does.
    enum Launch: UInt8, Sendable {
        case normal = 0, startHidden = 1, exitAndUnregister = 2
    }

    /// The env override of the hidden plan (`keep` or `close`), for the launch harness.
    static let planOverrideVariable = "CMUX_NEXT_BACKGROUND_READY_PLAN"

    static func mode(_ value: String) -> Mode {
        #if canImport(CCmuxBackgroundReadyFFI)
        Mode(rawValue: value.withCString { cmux_background_ready_mode_parse($0) }) ?? .off
        #else
        .off
        #endif
    }

    /// The library's number for `origin`.
    static func originCode(_ origin: QuitOrigin) -> UInt8 {
        switch origin {
        case .interactive: 0
        case .explicit: 1
        case .scripted: 2
        case .powerOff: 3
        case .signal: 4
        }
    }

    /// Whether this quit leaves cmux running hidden instead of ending it.
    static func staysHidden(_ mode: Mode, origin: QuitOrigin, updateInstallsOnQuit: Bool, quitCompletely: Bool) -> Bool {
        #if canImport(CCmuxBackgroundReadyFFI)
        cmux_background_ready_on_quit(mode.rawValue, originCode(origin), updateInstallsOnQuit, quitCompletely) == 1
        #else
        false
        #endif
    }

    static func hiddenPlan(_ mode: Mode, startedAtLogin: Bool, override: String?) -> HiddenPlan {
        #if canImport(CCmuxBackgroundReadyFFI)
        let code = if let override { override.withCString { cmux_background_ready_hidden_plan(mode.rawValue, startedAtLogin, $0) } }
            else { cmux_background_ready_hidden_plan(mode.rawValue, startedAtLogin, nil) }
        return HiddenPlan(rawValue: code) ?? .keepWindows
        #else
        .keepWindows
        #endif
    }

    static func registersLoginItem(_ mode: Mode) -> Bool {
        #if canImport(CCmuxBackgroundReadyFFI)
        cmux_background_ready_registers_login_item(mode.rawValue)
        #else
        false
        #endif
    }

    /// Whether the login-time pre-read agent is registered (Warm at Login only; ``BackgroundReadyPrereadAgent``).
    static func registersPrereadAgent(_ mode: Mode) -> Bool {
        #if canImport(CCmuxBackgroundReadyFFI)
        cmux_background_ready_registers_preread_agent(mode.rawValue)
        #else
        false
        #endif
    }

    /// Whether Quit Completely is offered: only while a mode keeps a hidden copy (Warm at Login keeps nothing).
    static func offersQuitCompletely(_ mode: Mode) -> Bool {
        #if canImport(CCmuxBackgroundReadyFFI)
        cmux_background_ready_offers_quit_completely(mode.rawValue)
        #else
        false
        #endif
    }

    static func atLaunch(_ mode: Mode, launchedAsLoginItem: Bool) -> Launch {
        #if canImport(CCmuxBackgroundReadyFFI)
        Launch(rawValue: cmux_background_ready_at_launch(mode.rawValue, launchedAsLoginItem)) ?? .normal
        #else
        .normal
        #endif
    }

    /// Whether a hidden cmux quits for good so Sparkle installs the staged update.
    static func exitsForUpdate(_ mode: Mode, hidden: Bool, updateStaged: Bool) -> Bool {
        #if canImport(CCmuxBackgroundReadyFFI)
        cmux_background_ready_exits_for_update(mode.rawValue, hidden, updateStaged)
        #else
        hidden && updateStaged
        #endif
    }

    /// Whether the Chromium warm-up starts now, under `plan`, shown or not.
    static func startsChromiumWarmup(_ plan: HiddenPlan, shown: Bool) -> Bool {
        #if canImport(CCmuxBackgroundReadyFFI)
        cmux_background_ready_starts_chromium_warmup(plan.rawValue, shown)
        #else
        true
        #endif
    }
}
