public import AppKit

/// `BrowserDevToolsHosting` and the page/DevTools occlusion. The DevTools
/// placement itself lives in `CEFDevToolsController` (`devToolsController`).
extension CEFTab {
    public func performDevTools(_ command: BrowserDevToolsCommand) {
        devToolsController.perform(command)
    }

    public func setDevToolsFocused(_ focused: Bool) {
        devToolsController.setFocused(focused)
    }

    public func devToolsContains(window: NSWindow) -> Bool {
        devToolsController.contains(window: window)
    }

    /// Screen frames of the page area and the docked DevTools area (nil
    /// when not in a window), for `debug.cef`.
    public var devToolsDiagnosticFrames: (page: CGRect, devTools: CGRect?)? {
        devToolsController.diagnosticFrames
    }

    /// The page's and DevTools' occlusion: the chrome's rects, plus holes
    /// for the divider's grab area so the mouse reaches it over both. Until
    /// the tab's first real page (the New Tab page, a blank page) the whole
    /// page is a hole: Chromium's windowed page cannot be transparent, so
    /// the window's backdrop shows there as in a WebKit tab (Lawrence
    /// 2026-10-10, `PageBackground`).
    func applyOcclusion() {
        let frames = devToolsController.frames(in: container.bounds)
        if host.visibleTab === self {
            let pageFrame = host.hostView.frame
            var rects = occlusionRects
            if !pastFirstRealPage {
                // An open side panel is part of the page window: only the web contents' part is a hole.
                let panel = sidePanel.headerFrame != nil ? sidePanel.state : nil
                rects.append(panel?.contentsFrame(inPage: pageFrame) ?? pageFrame)
            }
            if !frames.grab.isEmpty { rects.append(frames.grab) }
            if let header = sidePanel.headerFrame { rects.append(header) }
            host.hostView.occlusionRects = CEFHostView.outermost(Self.local(rects, in: pageFrame))
            host.hostView.roundedOcclusions = roundedOcclusions.compactMap { hole in
                guard hole.rect.intersects(pageFrame) else { return nil }
                return CEFClipShape.RoundedRect(rect: hole.rect.offsetBy(dx: -pageFrame.minX, dy: -pageFrame.minY), radius: hole.radius)
            }
        }
        if let views = devToolsController.views {
            if devToolsController.deviceModeActive {
                // Device mode: DevTools cover the content view; the page shows (and takes the mouse) through this hole.
                views.host.occlusionRects = Self.local([frames.page], in: views.host.frame)
            } else {
                views.host.occlusionRects = frames.grab.isEmpty ? [] : Self.local([frames.grab], in: views.host.frame)
            }
        }
    }

    /// The holes the page window has now, in `contentView` coordinates:
    /// the chrome's rects, the divider's grab area, the side panel header,
    /// and the web contents before the first real page. A window snapshot
    /// cuts the same holes, so it shows the page as the screen does
    /// (`debug.window_snapshot`); a rounded bar's hole is its whole rect there.
    public var pageWindowHoles: [CGRect] {
        let bars = roundedOcclusions.map(\.rect)
        guard host.visibleTab === self, host.hostView.superview === container else { return CEFHostView.outermost(occlusionRects + bars) }
        let frame = host.hostView.frame
        return CEFHostView.outermost(host.hostView.occlusionRects.map { $0.offsetBy(dx: frame.minX, dy: frame.minY) } + bars)
    }

    /// `rects` (content view coordinates) in a subview at `frame`.
    private static func local(_ rects: [CGRect], in frame: CGRect) -> [CGRect] {
        rects.compactMap { rect in
            let clipped = rect.intersection(frame)
            guard !clipped.isNull, !clipped.isEmpty else { return nil }
            return clipped.offsetBy(dx: -frame.minX, dy: -frame.minY)
        }
    }
}

/// The prompt and find bars leave the page as rounded holes (`roundedOcclusions`).
extension CEFTab: BrowserRoundedOcclusionHosting {}
