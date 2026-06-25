public import CmuxSessionIndex
import Foundation

// MARK: - Session row presentation strings

extension SessionEntry {
    /// The multi-line hover tooltip for a full session row: the display title, the
    /// optional working-directory label, and the absolute modified time.
    ///
    /// `displayTitle` is resolved app-side (it binds `String(localized:)` against
    /// the app bundle, so it cannot be recomputed inside this package) and passed
    /// in, mirroring how the call site already feeds `SessionRow.displayTitle`. The
    /// working-directory label and absolute time are derived here from the
    /// package-public ``cwdLabel`` and ``modified`` fields, the latter formatted by
    /// the locale-driven ``absoluteFormatter`` (`.medium` date + `.short` time).
    /// - Parameter displayTitle: The app-resolved, localized row title.
    /// - Returns: The newline-joined tooltip lines.
    public func sessionRowHelpText(displayTitle: String) -> String {
        var lines: [String] = [displayTitle]
        if let cwd = cwdLabel {
            lines.append(cwd)
        }
        lines.append(Self.absoluteFormatter.string(from: modified))
        return lines.joined(separator: "\n")
    }

    /// Locale-driven formatter for a session row's absolute modified time.
    /// Mirrors the identical private-static pattern in `CmuxFeedUI`'s
    /// `FeedItemRow.absoluteFormatter`.
    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
