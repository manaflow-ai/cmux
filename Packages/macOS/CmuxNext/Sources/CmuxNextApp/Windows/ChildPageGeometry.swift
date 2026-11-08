import AppKit
import CmuxNextBrowser

/// Invariant: every visible Chromium page window covers its pane's page
/// area exactly, in screen coordinates, whatever moved or resized the
/// window (drag, an Accessibility client such as Rectangle, a display,
/// Space or fullscreen change). Pages are child windows; the fork places
/// them from the host view's rect.
enum ChildPageGeometry {
    /// One pane showing a Chromium page, and where its page must be.
    struct Host: Equatable {
        var pane: String
        var screenRect: CGRect
    }

    /// Pixel rounding: the fork places windows on whole points.
    static let tolerance: CGFloat = 1

    static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
    }

    /// Violations: a host with no page window at its rect, or a visible page
    /// window at no host's rect.
    static func mismatches(hosts: [Host], pages: [CGRect]) -> [String] {
        var problems: [String] = []
        for host in hosts where !pages.contains(where: { distance($0, host.screenRect) <= tolerance }) {
            let nearest = pages.min { distance($0, host.screenRect) < distance($1, host.screenRect) }
            problems.append("pane \(host.pane): page \(nearest.map { "\($0)" } ?? "missing") != host \(host.screenRect)")
        }
        for page in pages where !hosts.contains(where: { distance(page, $0.screenRect) <= tolerance }) {
            problems.append("page window \(page) covers no pane")
        }
        return problems
    }

    /// Where the Chromium windows of one pane must be: the tab content, or,
    /// with DevTools docked, the page area and the DevTools area of the
    /// dock layout (each is its own child window). An undocked DevTools
    /// window is top-level, not a child of the cmux window, so it is not
    /// checked here.
    static func expectedHosts(pane: String, contentRect: CGRect, devTools: (page: CGRect, devTools: CGRect?)?) -> [Host] {
        guard let devTools, let docked = devTools.devTools else { return [Host(pane: pane, screenRect: contentRect)] }
        return [Host(pane: pane, screenRect: devTools.page), Host(pane: "\(pane) devtools", screenRect: docked)]
    }

    /// The window's Chromium hosts (visible panes showing any child-window page: a New Tab page too, G1) and page windows now.
    static func sample(_ controller: WindowController) -> (hosts: [Host], pages: [CGRect]) {
        guard let window = controller.window else { return ([], []) }
        var hosts: [Host] = []
        for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
            guard let page = pane.currentContent?.childWindowTab else { continue }
            let content = page.contentView
            guard content.window === window, !content.isHiddenOrHasHiddenAncestor, !content.bounds.isEmpty else { continue }
            let contentRect = window.convertToScreen(content.convert(content.bounds, to: nil))
            let devTools = (page as? CEFTab)?.devToolsDiagnosticFrames
            hosts += expectedHosts(pane: pane.paneKey, contentRect: contentRect, devTools: devTools)
        }
        let pages = window.isVisible ? WindowOverlayLayer.contentChildWindows(of: window).map(\.frame).filter { page in NSScreen.screens.contains { $0.frame.intersects(page) } || hosts.contains { distance(page, $0.screenRect) <= tolerance } } : [] // off every screen (the New Tab spare): covers nothing; at its host's rect (a pane past the display edge): kept
        return (hosts, pages)
    }
}
