#if DEBUG
import SwiftUI

/// A parsed deep route into the design gallery, used by the DEBUG
/// `CMUX_DESIGN_GALLERY` environment entry point.
///
/// Accepted forms, colon-separated and case-insensitive:
/// - `1` — the gallery root (system list)
/// - `<system>` — one candidate at its hub page, e.g. `phosphor`
/// - `<system>:<page>` — one candidate at a page, e.g. `atelier:chat`
/// - `<system>:<page>:<light|dark>` — with a forced color scheme,
///   e.g. `phosphor:specimen:light`
///
/// Unrecognized systems, pages, or schemes fall back component-wise (root,
/// `.hub`, and the system's default scheme respectively) so a typo still
/// lands somewhere useful in a debug run.
struct DesignGalleryRoute: Equatable {
    /// The candidate to open, or `nil` for the gallery root list.
    let system: DesignGallerySystem?
    /// The page to open when a candidate is routed.
    let page: DesignGalleryPage
    /// The forced color scheme, or `nil` for the candidate's default.
    let scheme: ColorScheme?

    /// Parses a route from the raw environment-variable value.
    /// - Parameter environmentValue: The value of `CMUX_DESIGN_GALLERY`.
    /// - Returns: `nil` when the value is empty or `0` (gallery disabled).
    init?(environmentValue: String) {
        let trimmed = environmentValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed != "0" else { return nil }

        let parts = trimmed.split(separator: ":").map(String.init)
        self.system = parts.first.flatMap(DesignGallerySystem.init(rawValue:))
        self.page = parts.count > 1 ? DesignGalleryPage(rawValue: parts[1]) ?? .hub : .hub
        switch parts.count > 2 ? parts[2] : nil {
        case "light": self.scheme = .light
        case "dark": self.scheme = .dark
        default: self.scheme = nil
        }
    }
}
#endif
