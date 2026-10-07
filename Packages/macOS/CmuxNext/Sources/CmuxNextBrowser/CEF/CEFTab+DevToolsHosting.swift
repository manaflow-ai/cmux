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
    /// for the divider's grab area so the mouse reaches it over both.
    func applyOcclusion() {
        let frames = devToolsController.frames(in: container.bounds)
        if host.visibleTab === self {
            let pageFrame = host.hostView.frame
            var rects = occlusionRects
            if !frames.grab.isEmpty { rects.append(frames.grab) }
            if let header = sidePanel.headerFrame { rects.append(header) }
            host.hostView.occlusionRects = Self.local(rects, in: pageFrame)
        }
        if let views = devToolsController.views {
            views.host.occlusionRects = frames.grab.isEmpty ? [] : Self.local([frames.grab], in: views.host.frame)
        }
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
