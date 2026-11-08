import Darwin

/// Keeps AppKit and CoreUI's in-process numeric parsing independent of
/// Ghostty's user-locale initialization.
struct GhosttyNumericLocaleController {
    /// Pins only `LC_NUMERIC` to the POSIX locale for the host process.
    ///
    /// Ghostty still receives the user's locale through `LANG` and the other
    /// C locale categories remain unchanged. Terminal child processes inherit
    /// the environment rather than this in-process category override.
    @discardableResult
    func pinProcessNumericLocale() -> Bool {
        setlocale(LC_NUMERIC, "C") != nil
    }
}
