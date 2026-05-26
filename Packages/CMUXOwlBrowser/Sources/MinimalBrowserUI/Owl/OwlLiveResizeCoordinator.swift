import AppKit
import MinimalBrowserCore
import OwlMojoBindingsGenerated

@MainActor
final class OwlLiveResizeCoordinator {
    enum Phase: Equatable {
        case idle
        case liveResizing(OwlHostViewport)
        case awaitingFrame(OwlHostViewport)
        case confirmed(OwlHostViewport)
    }

    private(set) var phase: Phase = .idle
    private var lastSentViewport: OwlHostViewport?

    func beginLiveResize(currentViewport: OwlHostViewport?) {
        if let currentViewport {
            phase = .liveResizing(currentViewport)
        }
    }

    func endLiveResize(
        viewport: OwlHostViewport,
        engine: BrowserEngine,
        tabID: BrowserTab.ID
    ) throws {
        try sendViewport(viewport, engine: engine, tabID: tabID, force: true)
    }

    func viewportDidChange(
        _ viewport: OwlHostViewport,
        engine: BrowserEngine,
        tabID: BrowserTab.ID,
        force: Bool = false
    ) throws {
        try sendViewport(viewport, engine: engine, tabID: tabID, force: force)
    }

    func confirm(surfaceTree: OwlFreshSurfaceTree?) {
        guard let surfaceTree else {
            return
        }
        guard let webView = surfaceTree.surfaces.first(where: { $0.kind == .webView && $0.visible }) else {
            return
        }
        let confirmed = OwlHostViewport(
            size: CGSize(width: CGFloat(webView.width), height: CGFloat(webView.height)),
            scale: CGFloat(webView.scale)
        )
        guard confirmed == lastSentViewport else {
            return
        }
        phase = .confirmed(confirmed)
    }

    func reset() {
        phase = .idle
        lastSentViewport = nil
    }

    private func sendViewport(
        _ viewport: OwlHostViewport,
        engine: BrowserEngine,
        tabID: BrowserTab.ID,
        force: Bool
    ) throws {
        guard viewport.size.width >= 1, viewport.size.height >= 1 else {
            return
        }
        guard force || viewport != lastSentViewport else {
            return
        }
        try engine.resizeImmediately(tabID: tabID, size: viewport.size, scale: viewport.scale)
        lastSentViewport = viewport
        phase = .awaitingFrame(viewport)
    }
}

struct OwlHostViewport: Equatable {
    let size: CGSize
    let scale: CGFloat
}
