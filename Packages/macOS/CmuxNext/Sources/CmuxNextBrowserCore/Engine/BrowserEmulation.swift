public import Foundation

/// A device emulation as the daemon resolved it for one tab (the tab's
/// `extra.emulation`, browser-devices-v1, cx-ocbf3). The daemon owns the
/// device list, the choice and every value; an engine only applies them.
public nonisolated struct BrowserEmulation: Sendable, Hashable {
    /// The device's CSS viewport size.
    public var width: Int
    public var height: Int
    public var deviceScaleFactor: Double
    /// Empty keeps the engine's own user agent.
    public var userAgent: String
    /// The DevTools calls Chrome's device mode sends, as the daemon wrote
    /// them: JSON of `[{method, params}]`. A Chromium engine sends them as
    /// given, only lowering `Emulation.setDeviceMetricsOverride`'s `scale` so
    /// a device bigger than the pane fits (as Chrome does).
    public var chromiumCallsJSON: String
    /// Fit as a desktop (`mode: "fit"`): the engine sizes the layout from
    /// its view (`viewport(in:)`); `width` and `height` are 0.
    public var fit: Fit?
    /// The daemon tab the record belongs to (set by the App), so the fit bar's commands name it.
    public var tabID: String?

    /// The daemon's fit record: a layout as wide as the view would be at
    /// aspect `aspectWidth:aspectHeight` at its height, between `minWidth`
    /// and `maxWidth` CSS px, scaled down to the view's width; the layout is
    /// as tall as the view over that scale, so the page fills the view.
    public struct Fit: Sendable, Hashable {
        public var aspectWidth: Int
        public var aspectHeight: Int
        public var minWidth: Int
        public var maxWidth: Int
        /// The fit as given (`fit.value`: "16:9", "4:3", "1280"...).
        public var value: String

        public init(aspectWidth: Int, aspectHeight: Int, minWidth: Int, maxWidth: Int, value: String = "") {
            self.aspectWidth = aspectWidth
            self.aspectHeight = aspectHeight
            self.minWidth = minWidth
            self.maxWidth = maxWidth
            self.value = value
        }
    }

    /// The page's layout size and the scale that shows it in a view.
    public struct Viewport: Sendable, Hashable {
        public var size: CGSize
        public var scale: CGFloat

        package init(size: CGSize, scale: CGFloat) {
            self.size = size
            self.scale = scale
        }
    }

    public init(width: Int, height: Int, deviceScaleFactor: Double, userAgent: String, chromiumCallsJSON: String, fit: Fit? = nil) {
        self.width = width
        self.height = height
        self.deviceScaleFactor = deviceScaleFactor
        self.userAgent = userAgent
        self.chromiumCallsJSON = chromiumCallsJSON
        self.fit = fit
    }

    /// The layout size and scale in a view of `available` points: the
    /// device's size at its fit scale, or for a fit the desktop layout that
    /// fills the view's height (scaled down to its width; in a wider view it
    /// shows at scale 1, centered by `presentedRect`). Nil for an empty view.
    public func viewport(in available: CGSize) -> Viewport? {
        guard let fit else {
            guard width > 0, height > 0 else { return nil }
            return Viewport(size: CGSize(width: width, height: height), scale: fitScale(in: available))
        }
        guard available.width >= 1, available.height >= 1, fit.aspectWidth > 0, fit.aspectHeight > 0 else { return nil }
        let wanted = (available.height * CGFloat(fit.aspectWidth) / CGFloat(fit.aspectHeight)).rounded()
        let layoutWidth = min(max(wanted, CGFloat(fit.minWidth)), CGFloat(max(fit.minWidth, fit.maxWidth)))
        let scale = min(1, available.width / layoutWidth)
        // Rounded down: the page never runs past the view's bottom edge.
        let layoutHeight = max(1, (available.height / scale).rounded(.down))
        return Viewport(size: CGSize(width: layoutWidth, height: layoutHeight), scale: scale)
    }

    /// A fit leaves this margin around the page (top, sides) and a bar under
    /// it (`BrowserFitFrameView`): the backdrop and hairline show the
    /// emulated viewport's bounds, and the bar says what is happening.
    public static let fitMargin: CGFloat = 6
    public static let fitBarHeight: CGFloat = 30

    /// The area a fit lays the page out in, inside `page` (AppKit, not flipped:
    /// the bar is at minY); `page` itself for a device or no fit.
    public func layoutArea(in page: CGRect) -> CGRect {
        guard fit != nil else { return page }
        let (margin, bar) = (Self.fitMargin, Self.fitBarHeight)
        let area = CGRect(x: page.minX + margin, y: page.minY + bar, width: page.width - 2 * margin, height: page.height - margin - bar)
        return area.width >= 1 && area.height >= 1 ? area : page
    }

    /// Where a fit shows the scaled page inside `page`: centered left to
    /// right in `layoutArea(in:)`, flush with its top. Nil for a device or no fit.
    public func presentedRect(in page: CGRect) -> CGRect? {
        guard fit != nil else { return nil }
        let area = layoutArea(in: page)
        guard let viewport = viewport(in: area.size) else { return nil }
        let size = CGSize(width: min(area.width, (viewport.size.width * viewport.scale).rounded()),
                          height: min(area.height, (viewport.size.height * viewport.scale).rounded()))
        return CGRect(x: (area.midX - size.width / 2).rounded(.down), y: area.maxY - size.height, width: size.width, height: size.height)
    }

    /// The scale that fits the device in `available` points (at most 1), in
    /// whole percent rounded down, as Chrome's `calculateFitScale`.
    public func fitScale(in available: CGSize) -> CGFloat {
        guard available.width > 0, available.height > 0, width > 0, height > 0 else { return 1 }
        let scale = min(1, available.width / CGFloat(width), available.height / CGFloat(height))
        return max(0.01, (scale * 100).rounded(.down) / 100)
    }
}

/// A tab whose engine applies the daemon's emulation record.
@MainActor
public protocol BrowserEmulating: AnyObject {
    /// The record the tab applies, nil for none.
    var deviceEmulation: BrowserEmulation? { get }
    /// Applies `emulation` (nil ends it) and keeps it across navigations.
    func applyEmulation(_ emulation: BrowserEmulation?)
}
