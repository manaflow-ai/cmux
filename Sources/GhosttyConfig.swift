import CmuxTerminalCore

/// App-target alias for ``CmuxTerminalCore/GhosttyConfig``, lifted into
/// CmuxTerminalCore in stack D tranche A. Keeps every `GhosttyConfig` call site
/// (and `GhosttyConfig.ColorSchemePreference` / `GhosttyConfig.UserAppearanceConfigSummary`
/// member lookups) byte-identical across the app target.
typealias GhosttyConfig = CmuxTerminalCore.GhosttyConfig
