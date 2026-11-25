public import Foundation
import CoreText
import os

/// The active theme file's own font files (`"fonts"`, a theme pack's faces), registered for this
/// process while the file applies, so the terminal and native text find the families the look names
/// (`terminal.fontFamily`) like installed ones. The files were checked by the pack loader (Rust,
/// `cmux-theme-pack`); a file CoreText refuses is logged and skipped. Nothing is installed for the
/// Mac: a font leaves with its look. The settings controller owns one.
@MainActor
public final class ThemeFonts {
    private var registered: [URL] = []
    private let log = Logger(subsystem: "com.cmuxterm.next", category: "theme-fonts")

    public init() {}

    /// Registers `files` and unregisters the ones registered before that `files` no longer lists.
    public func use(_ files: [URL]) {
        guard files != registered else { return }
        for url in registered where !files.contains(url) {
            var error: Unmanaged<CFError>?
            if !CTFontManagerUnregisterFontsForURL(url as CFURL, .process, &error) {
                log.error("unregister \(url.path, privacy: .public): \(String(describing: error?.takeRetainedValue()), privacy: .public)")
            }
        }
        for url in files where !registered.contains(url) {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                log.error("register \(url.path, privacy: .public): \(String(describing: error?.takeRetainedValue()), privacy: .public)")
            }
        }
        registered = files
    }
}
