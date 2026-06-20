public import CmuxTerminalCore
public import GhosttyKit

/// The embedded-Ghostty engine capability cmux constructs once and forwards
/// engine-side work through, replacing the legacy `GhosttyApp` god type and its
/// `GhosttyApp.shared` singleton.
///
/// This is the first stage of draining `GhosttyApp` into `CmuxTerminal`. It
/// owns the engine side effects and config-runtime reads that do not touch the
/// live `ghostty_app_t`/`ghostty_config_t` mutation spine: the terminal bell
/// and the read-only `ghostty_config_t` accessors (`focus-follows-mouse`,
/// `scrollbar`, `macos-applescript`). The stateful orchestration that owns the
/// handles (engine initialization, config reload, appearance/color-scheme sync,
/// default-background resolution) and the runtime tick/`handleAction` dispatch
/// stay on the app-target `GhosttyApp` for now, because they share the
/// `app`/`config` handles with the hot-path action callback; that orchestration
/// drains here in later slices once the `handleAction` fan-out is inverted.
///
/// Isolation design: every method here is a pure function of a caller-owned
/// `ghostty_config_t` plus AppKit bell side effects. The legacy `GhosttyApp`
/// was a non-isolated, non-`Sendable` class whose engine state was touched only
/// from the main thread by convention (the runtime bell callback marshals to
/// main via `performOnMain`; the config accessors are read from main-thread
/// `NSView` methods). This service preserves that exact shape as a plain
/// non-isolated, non-`Sendable` class, so the existing call sites stay
/// byte-identical and no isolation boundary is introduced. The eventual
/// stateful config/appearance orchestration that drains here later is
/// single-writer main-thread state and will adopt `@MainActor @Observable` when
/// it moves; this leaf carries no such state, so annotating it now would only
/// ripple `@MainActor` onto the non-isolated `NSView` readers without behavior
/// benefit.
public final class GhosttyAppService {
    /// Terminal bell side effects (was the `GhosttyApp.terminalBell` slot): the
    /// system beep, audio-file playback, and dock-attention request, plus the
    /// `NSSound` strong reference that keeps an asynchronously playing sound
    /// alive.
    private let bell: TerminalBellService

    /// Creates an engine service with a fresh terminal bell.
    public init() {
        self.bell = TerminalBellService()
    }

    /// Rings the terminal bell by decoding the `bell-features`, `bell-audio-path`,
    /// and `bell-audio-volume` directives from the live `config` handle and
    /// applying the resolved AppKit side effects.
    ///
    /// The flag/path/volume reads decode `config` here; the side effects live in
    /// the owned ``TerminalBellService``. Matches the legacy `GhosttyApp.ringBell`
    /// byte-for-byte (a `nil` `config` decodes to no features, no audio, default
    /// volume, so the bell is a no-op).
    public func ringBell(config: ghostty_config_t?) {
        bell.ring(
            features: GhosttyConfig.bellFeatures(in: config),
            audioPath: GhosttyConfig.bellAudioPath(in: config),
            audioVolume: GhosttyConfig.bellAudioVolume(in: config)
        )
    }

    /// Whether ghostty's `focus-follows-mouse` directive is enabled in `config`.
    ///
    /// Replaces `GhosttyApp.focusFollowsMouseEnabled()`; a `nil` handle returns
    /// `false`, matching the legacy accessor.
    public func focusFollowsMouseEnabled(config: ghostty_config_t?) -> Bool {
        GhosttyConfig.focusFollowsMouseEnabled(in: config)
    }

    /// The `scrollbar` directive in `config`, defaulting to
    /// ``GhosttyConfig/ScrollbarVisibility/system``.
    ///
    /// Replaces `GhosttyApp.scrollbarVisibility()`.
    public func scrollbarVisibility(config: ghostty_config_t?) -> GhosttyConfig.ScrollbarVisibility {
        GhosttyConfig.scrollbarVisibility(in: config)
    }

    /// Whether ghostty's `macos-applescript` directive is enabled in `config`.
    ///
    /// Replaces `GhosttyApp.appleScriptAutomationEnabled()`.
    public func appleScriptAutomationEnabled(config: ghostty_config_t?) -> Bool {
        GhosttyConfig.appleScriptAutomationEnabled(in: config)
    }
}
