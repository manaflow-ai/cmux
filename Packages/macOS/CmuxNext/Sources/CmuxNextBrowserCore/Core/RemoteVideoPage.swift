package import Foundation

/// The page a browser tab shows for a web video its server sends as a generic file
/// (`application/octet-stream`, as raw.githubusercontent.com serves every .mp4): without it the
/// tab downloads the file, where a server that says `video/mp4` gets the engine's own player.
/// A response marked as an attachment still downloads.
package nonisolated struct RemoteVideoPage {
    package nonisolated init() {}
    /// The video names a tab plays this way.
    package static let extensions: Set<String> = ["mp4", "m4v", "mov", "webm", "ogv"]

    /// Whether a main-frame response for `url` that would download plays here instead.
    package static func plays(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return extensions.contains(url.pathExtension.lowercased())
    }

    /// The player: the video alone, fitted to the tab on black, with the system's controls.
    package static func html(for url: URL) -> String {
        let source = escaped(url.absoluteString), title = escaped(url.lastPathComponent)
        return """
        <!doctype html><meta charset="utf-8"><title>\(title)</title>
        <style>html,body{margin:0;height:100%;background:#000}\
        video{display:block;width:100%;height:100%;object-fit:contain}</style>
        <video src="\(source)" controls autoplay playsinline></video>
        """
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
