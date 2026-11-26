public import CmuxNextSettings
public import CoreGraphics

/// One `cmux.changelog.surface.size` report as the page sent it (CSS px): `{height, width?, overlay?, preview?,
/// title?, settled?}`. `settled`: the Updated card's words are final (its notes answered), so the host stops
/// holding the height it remembered from the last showing (u51892); false when the page does not say.
public nonisolated struct PageSurfaceReport: Equatable, Sendable {
    public var height: CGFloat, width: CGFloat = 0, overlay: CGFloat = 0, preview: CGFloat = 0, title: CGFloat = 0
    public var settled = false

    public init(height: CGFloat, width: CGFloat = 0, overlay: CGFloat = 0, preview: CGFloat = 0, title: CGFloat = 0, settled: Bool = false) {
        (self.height, self.width, self.overlay, self.preview, self.title, self.settled) = (height, width, overlay, preview, title, settled)
    }

    /// The report in `params`; nil without a height.
    public init?(params: JSONValue) {
        guard let height = params["height"]?.doubleValue else { return nil }
        let number = { (key: String) in CGFloat(params[key]?.doubleValue ?? 0) }
        self.init(height: CGFloat(height), width: number("width"), overlay: number("overlay"), preview: number("preview"),
                  title: number("title"), settled: params["settled"]?.boolValue ?? false)
    }
}

/// The size a small page surface reports to its native host (the sidebar's update surfaces), in
/// points: its content height, its own width (0: it fills the host) and the room its open overlay
/// needs above it (0: none), the height its open overlay has once open (0: closed or closing), and
/// where its title line's middle is, down from the top of its card (0: no title; the host centers its
/// native close button on it, u51892).
/// The page reports CSS px; the page is zoomed (the interface scale), so
/// one CSS px is `zoom` points.
public nonisolated struct PageSurfaceSize: Equatable, Sendable {
    public private(set) var height: CGFloat = 0
    public private(set) var width: CGFloat = 0
    public private(set) var overlay: CGFloat = 0
    public private(set) var preview: CGFloat = 0
    /// The title line's middle, down from the card's top: not rounded up as the sizes are (it places a
    /// control on a line, so a point up would sit it off the line), to a quarter point.
    public private(set) var title: CGFloat = 0
    /// The page's words were final at its last report (``PageSurfaceReport/settled``).
    public private(set) var settled = false
    /// A report has arrived: the first one counts as a change even when it is all 0 (a page with
    /// nothing to show).
    public private(set) var reported = false
    /// The last report as the page sent it, CSS px, so a new zoom can take it again.
    private var cssHeight: CGFloat = 0, cssWidth: CGFloat = 0, cssOverlay: CGFloat = 0, cssPreview: CGFloat = 0, cssTitle: CGFloat = 0

    public init() {}

    /// Takes one report; true when the host must lay the surface out again (its sizes, title line or
    /// settled state changed).
    public mutating func take(_ report: PageSurfaceReport, zoom: CGFloat) -> Bool {
        let settledChanged = report.settled != settled
        settled = report.settled
        let moved = take(height: report.height, width: report.width, overlay: report.overlay, preview: report.preview,
                         title: report.title, zoom: zoom)
        return moved || settledChanged
    }

    /// Takes one report's sizes; true when the host must lay the surface out again.
    public mutating func take(height: CGFloat, width: CGFloat, overlay: CGFloat, preview: CGFloat = 0, title: CGFloat = 0,
                              zoom: CGFloat) -> Bool {
        (cssHeight, cssWidth, cssOverlay, cssPreview, cssTitle) = (height, width, overlay, preview, title)
        let points = { (value: CGFloat) in max(0, (value * zoom).rounded(.up)) }
        let line = max(0, (title * zoom * 4).rounded() / 4)
        let next = (points(height), points(width), points(overlay), points(preview))
        guard next != (self.height, self.width, self.overlay, self.preview) || line != self.title || !reported else { return false }
        (self.height, self.width, self.overlay, self.preview, self.title, reported) = (next.0, next.1, next.2, next.3, line, true)
        return true
    }

    /// Takes the last report again at a new zoom (a live interface scale change: the page's CSS size
    /// stays, so it sends no new report); true when the host must lay the surface out again.
    public mutating func rezoom(_ zoom: CGFloat) -> Bool {
        guard reported else { return false }
        return take(height: cssHeight, width: cssWidth, overlay: cssOverlay, preview: cssPreview, title: cssTitle, zoom: zoom)
    }
}
