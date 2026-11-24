public import Foundation

/// The first cmux page's own load times this launch (startup-tti), from inside the page: its navigation start
/// (`performance.timeOrigin`), its DOMContentLoaded (the navigation entry's `domContentLoadedEventStart`) and its first
/// contentful paint (the `first-contentful-paint` paint entry). The app asks the page once, when Chromium's first cmux
/// page is ready for keys (loaded and painted, so every entry is in), and marks each on the launch marks' clock. The
/// page's clock is the wall clock in milliseconds, as the marks' zero (`sysctl` `p_starttime`) is.
/// Leo, 2026-11-21: "you can build instrumentation if you havent already to properly measure each part of startup times."
public nonisolated struct LaunchFirstPage {
    public nonisolated init() {}
    public static let navigationStart = "first_page.navigation_start"
    public static let domContentLoaded = "first_page.dom_content_loaded"
    public static let firstContentfulPaint = "first_page.first_contentful_paint"

    /// The page's answer: `origin,dcl,fcp` in milliseconds, `origin` since 1970 and the other two since `origin`, -1
    /// for an entry the page does not have. Runs in an isolated world, which shares the frame's performance timeline.
    public static let script = """
    (() => {
      const p = performance, nav = p.getEntriesByType('navigation')[0], fcp = p.getEntriesByName('first-contentful-paint')[0];
      return [p.timeOrigin, nav ? nav.domContentLoadedEventStart : -1, fcp ? fcp.startTime : -1].join(',');
    })()
    """

    /// The launch marks `answer` (``script``'s) carries, each with when it happened; empty when it does not parse.
    /// An entry the page does not have, or a DOMContentLoaded that has not fired (0), is left out.
    public static func marks(_ answer: String) -> [(name: String, at: Date)] {
        let parts = answer.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3, let origin = parts[0], origin.isFinite, origin > 0 else { return [] }
        var out = [(name: navigationStart, at: Date(timeIntervalSince1970: origin / 1_000))]
        for (name, offset) in [(domContentLoaded, parts[1]), (firstContentfulPaint, parts[2])] {
            if let offset, offset.isFinite, offset > 0 { out.append((name, Date(timeIntervalSince1970: (origin + offset) / 1_000))) }
        }
        return out
    }
}
