public import Foundation

/// How far down the shown page was when its scrolling last settled, as the page itself reported
/// it (``BrowserScrollReportScript``). A scroll fires no navigation event, so without this the
/// position was only measured when the person left the app or quit, and a crash, or a quit whose
/// measure ran out of time, lost it.
public nonisolated struct BrowserScrollReport: Hashable, Sendable {
    /// The address the page had when it reported; a report applies only to that page.
    public var url: URL
    /// The page's `window.scrollY`, in CSS pixels.
    public var y: Double

    /// A report of `y` for the page at `url`.
    public init(url: URL, y: Double) {
        self.url = url
        self.y = y
    }

    /// The largest offset a report may carry; a renderer that posts more is not cmux's script.
    static let maxY = 10_000_000.0

    /// The position in a page's report: a finite, non-negative number of pixels, else nil
    /// (the payload is untrusted page data).
    static func y(fromPayload payload: String) -> Double? {
        guard let y = Double(payload.trimmingCharacters(in: .whitespaces)), y.isFinite, y >= 0, y <= maxY else { return nil }
        return y.rounded()
    }
}
