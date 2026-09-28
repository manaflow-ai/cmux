import AppKit
import CmuxFoundation
import CmuxTerminalCore
import Foundation

/// Reads and parses the `emptyPane.artFile` art, and pairs it with the
/// terminal's current font and palette.
struct EmptyPaneArtLoader: Sendable {
    private let parser = ANSIArtParser()

    /// Parses the art at `path`.
    ///
    /// - Returns: `nil` when the path is empty or is not a readable regular
    ///   file within the parser's size cap with visible content, so the pane
    ///   shows its default view.
    func art(atPath path: String) -> ANSIArt? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Resolve symlinks so dotfile managers that link the art file work.
        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).resolvingSymlinksInPath()
        // Only regular files: opening a FIFO or device would block or never end.
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let handle = try? FileHandle(forReadingFrom: url) else {
            Self.logFallback("unreadable", url: url)
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: parser.maxBytes + 1),
              let art = parser.parse(data: data) else {
            Self.logFallback("empty or over \(parser.maxBytes) bytes", url: url)
            return nil
        }
        return art
    }

    /// The art with the terminal's font family, font size and colors.
    func content(for art: ANSIArt, config: GhosttyConfig) -> EmptyPaneArtView.Content {
        EmptyPaneArtView.Content(
            art: art,
            palette: ANSIArtPalette(
                foreground: ANSIArtRGB(config.foregroundColor),
                background: ANSIArtRGB(config.backgroundColor),
                overrides: config.palette.mapValues { ANSIArtRGB($0) }
            ),
            fontFamily: config.fontFamily,
            preferredFontSize: config.fontSize
        )
    }

    private static func logFallback(_ reason: String, url: URL) {
        #if DEBUG
        cmuxDebugLog("emptyPane.art fallback reason=\(reason) file=\(url.lastPathComponent)")
        #endif
    }
}
