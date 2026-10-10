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
            host.hostView.occlusionRects = Self.local(rects, in: pageFrame)
        }
        if let views = devToolsController.views {
            views.host.occlusionRects = frames.grab.isEmpty ? [] : Self.local([frames.grab], in: views.host.frame)
        }
    }

    /// The holes the page window has now, in `contentView` coordinates:
    /// the chrome's rects, the divider's grab area, the side panel header,
    /// and the web contents before the first real page. A window snapshot
    /// cuts the same holes, so it shows the page as the screen does
    /// (`debug.window_snapshot`).
    public var pageWindowHoles: [CGRect] {
        guard host.visibleTab === self, host.hostView.superview === container else { return occlusionRects }
        let frame = host.hostView.frame
        return host.hostView.occlusionRects.map { $0.offsetBy(dx: frame.minX, dy: frame.minY) }
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
