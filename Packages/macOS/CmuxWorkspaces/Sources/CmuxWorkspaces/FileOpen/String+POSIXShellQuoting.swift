import Foundation

extension String {
    /// The string wrapped in POSIX single quotes, with embedded single
    /// quotes escaped via the standard `'\''` splice — byte-identical to the
    /// legacy `PreferredEditorSettings.shellQuote`.
    var posixShellSingleQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
