/// The cmux-managed macOS `scrollback-limit` default.
///
/// Ghostty's stock default is 10,000,000 bytes per surface. The memory audit
/// for issue #7596 measured about 799 MB in `MALLOC_SMALL` blocks from 177
/// surfaces at that default. iOS already applies a 2 MB limit in
/// `Packages/iOS/CmuxMobileTerminal/Sources/CmuxMobileTerminal/GhosttyRuntime.swift`
/// via `applyiOSDefaults`; macOS keeps a larger 4 MB default because local
/// terminal users scroll locally. Runtime config loads this directive before
/// user config files, so an explicit user `scrollback-limit` overrides it.
extension GhosttyConfig {
    /// The cmux-managed macOS default `scrollback-limit`, in bytes.
    public static let defaultScrollbackLimitBytes: Int = 4_000_000

    /// The Ghostty config directive loaded before user config files.
    public static let defaultScrollbackLimitConfigDirective: String =
        "scrollback-limit = \(defaultScrollbackLimitBytes)"
}
