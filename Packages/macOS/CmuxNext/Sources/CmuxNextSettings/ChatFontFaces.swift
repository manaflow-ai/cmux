import Foundation

/// The font files the agent chat declares (`agentPane.display.font.faces`), so a theme's font pack
/// can ship the faces its `font.uiFamily` and `font.proseFamily` name. Rust reads them
/// (cmux-tui/crates/cmux-config/src/font_faces.rs, the reader `cmux theme check` uses too, through
/// app_ops/effective.rs `font_faces.load`).
///
/// The setting is a map: key = one family name, optionally suffixed `:italic`; value = `file:PATH`,
/// absolute or at `~` (a theme file's relative path already resolved against the themes folder,
/// ``ThemeFileOverlay``). A face is a plain file (no symbolic link) of at most 2 MiB, with a
/// `woff2`, `woff`, `ttf` or `otf` extension that matches its first bytes; at most 8 are read, in
/// key order. Each becomes a `data:font/<kind>;base64,...` URL for the chat page, which declares it
/// as an `@font-face`. A bad entry is skipped; the rest apply.
///
/// ```swift
/// let faces = ChatFontFaces.Loader().dataURLs(["Lora:italic": "file:~/Fonts/Lora-Italic.woff2"])
/// // ["Lora:italic": "data:font/woff2;base64,d09GMg..."]
/// ```
public nonisolated struct ChatFontFaces {
    public nonisolated init() {}

    /// Reads faces maps into data URLs. Rust keeps each file's URL until its path, size or
    /// modification time changes, so a settings change that leaves the files alone reads none of
    /// them again. The chat's page settings own one (`AgentPanePageSettings`).
    public nonisolated final class Loader: Sendable {
        /// A loader.
        public init() {}

        /// Every good entry of a faces map as the page's `{family[:italic]: data URL}`; bad entries
        /// are skipped. File I/O: call it off the main thread.
        ///
        /// - Parameter faces: The setting's map.
        /// - Returns: The data URL of each face that loads, by page key.
        public func dataURLs(_ faces: [String: JSONValue]) -> [String: String] {
            let reply = SettingsRust.answer("font_faces.load", ["faces": .object(faces)])
            return (reply["faces"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
        }
    }
}
