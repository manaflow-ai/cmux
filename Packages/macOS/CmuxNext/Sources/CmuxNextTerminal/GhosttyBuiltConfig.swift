import CmuxNextDesign
import Foundation
import GhosttyNextKit

/// What one Ghostty config build reads besides the disk: cmux.json's overrides and the color scheme, copied on
/// the main actor when the build is asked for (``current(theme:)``), so the build itself reads no main-actor state
/// and runs on a lane (``buildConfig(fileID:line:)``).
nonisolated struct GhosttyConfigInputs: Sendable, Equatable {
    /// The theme spec loaded after the config files (`theme = <spec>`); nil keeps the files' theme.
    var theme: String?
    /// `appearance.themeEdits`, applied after the theme they edit.
    var themeEdits: ThemeEdits
    /// The light/dark side a pair's edits take.
    var isDark: Bool
    /// cmux.json's terminal font.
    var font: GhosttyRuntime.FontOverride
    /// cmux.json's window background, laid over the files' opacity and blur.
    var background: WindowBackgroundOverride
    /// The terminal host paints the background behind the cells (a terminal background override, or a
    /// see-through window): the surfaces draw a transparent default background (`GhosttyRuntimeSurfacePolicy`).
    var ownerPaintsBackground: Bool
    /// The one config file `CMUX_NEXT_GHOSTTY_CONFIG` names instead of the default files; nil reads the defaults.
    var configFile: String?
    /// cmux's Kitty graphics budget per screen, loaded when the config leaves `image-storage-limit` unset
    /// (``GhosttyRuntime/setImageStorageBytesPerScreen(_:)``); bounded by default, never Ghostty's own.
    var imageStorageBytes = GhosttyRuntime.defaultImageStorageBytesPerScreen

    /// The inputs of a build asked for now: the user's config with `theme` (a room, workspace or terminal theme)
    /// or, nil, with `themeOverride`. Records the see-through state the build reads
    /// (``GhosttyRuntime/seeThroughLoaded``).
    @MainActor static func current(theme: String?) -> GhosttyConfigInputs {
        typealias Runtime = GhosttyRuntime
        Runtime.seeThroughLoaded = Runtime.seeThroughShown
        let override = ProcessInfo.processInfo.environment[Runtime.configOverrideKey]
        return GhosttyConfigInputs(theme: theme ?? Runtime.themeOverride, themeEdits: Runtime.themeEdits,
                                   isDark: Runtime.colorSchemeIsDark, font: Runtime.fontOverride,
                                   background: Runtime.backgroundOverride,
                                   ownerPaintsBackground: Runtime.terminalBackgroundOverridden || Runtime.seeThroughShown,
                                   configFile: override.flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// One finalized Ghostty config built off the main thread, with what its build read from it, handed to the main
/// actor once (``GhosttyConfigLoading``). The main actor then owns `config`: it applies it or frees it.
public nonisolated final class GhosttyBuiltConfig: Sendable {
    /// The finalized config, carried across the reply as the module's reviewed C handle hand-off.
    private let handle: UncheckedPointer
    /// The finalized config (`ghostty_config_t`).
    /// SAFETY: the handle the build made and only one owner frees: the main actor adopts it
    /// (GhosttyRuntime's `config`, a GhosttyThemeConfig) or calls ``free()``, once.
    @safe var config: ghostty_config_t? {
        // SAFETY: as above; reading the address does not touch the config.
        unsafe handle.raw
    }
    /// `background-opacity` resolved with cmux.json's override, 0...1 (the surfaces may carry 0 instead).
    let opacity: Double
    /// The config files' own `background-opacity` and `background-blur`, before cmux.json's override
    /// (``GhosttyConfigBackground/loaded``).
    let filesOpacity: Double
    let filesBlur: Int
    /// libghostty's messages from the load (unknown keys, bad values).
    let diagnostics: [String]

    init(config: ghostty_config_t, opacity: Double, filesOpacity: Double, filesBlur: Int, diagnostics: [String]) {
        // SAFETY: the build hands over its new finalized config, which this object carries until its
        // one owner adopts or frees it (`config`'s note).
        self.handle = unsafe UncheckedPointer(raw: config)
        self.opacity = opacity
        self.filesOpacity = filesOpacity
        self.filesBlur = filesBlur
        self.diagnostics = diagnostics
    }

    /// Frees a config nothing adopted (a superseded build).
    func free() {
        // SAFETY: the owner frees a config nothing adopted, once (`config`'s note).
        unsafe ghostty_config_free(config)
    }
}
