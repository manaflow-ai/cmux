#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextSettings
import Foundation

/// Geometry and host state used by the deterministic native Session Info capture scene.
/// This is read-only DEBUG plumbing; the page remains the source of Session Info policy.
public struct AgentPaneSessionInfoDebugRect: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    init(_ rect: CGRect) {
        x = Double(rect.minX)
        y = Double(rect.minY)
        width = Double(rect.width)
        height = Double(rect.height)
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

/// A single frame's native Session Info state. ``frameReady`` compares the panel's measured
/// geometry with the page's CSS model, so a capture cannot silently pass with a short panel.
public struct AgentPaneSessionInfoDebugState: Sendable, Equatable {
    public let nativeHost: Bool
    public let open: Bool
    public let panel: AgentPaneSessionInfoDebugRect?
    public let page: AgentPaneSessionInfoDebugRect?
    public let top: Double?
    public let foot: Double?
    public let zoom: Double
    public let sectionCount: Int
    public let flipped: Bool

    public var visible: Bool { nativeHost && open && panel != nil && (panel?.height ?? 0) > 0 }

    /// Whether the native panel starts below the model's top inset and ends at its modeled foot.
    /// AppKit's flipped coordinate system reverses which frame edge is the top.
    public var frameReady: Bool {
        guard let panel, let page, let top, visible else { return false }
        let expectedTop = top * zoom
        let expectedFoot = (foot ?? 8) * zoom
        let actualTop = flipped ? panel.minY - page.minY : page.maxY - panel.maxY
        let actualFoot = flipped ? page.maxY - panel.maxY : panel.minY - page.minY
        return abs(actualTop - expectedTop) <= 2 && abs(actualFoot - expectedFoot) <= 2
    }

    public var ready: Bool { visible && frameReady && sectionCount > 0 }
}

extension AgentPaneView {
    /// The native Session Info host/model/panel geometry for capture assertions.
    public var debugSessionInfoState: AgentPaneSessionInfoDebugState {
        let info = model.sessionInfo.info
        let pageFrame = page?.frame ?? webView.frame
        let panelFrame = model.sessionInfo.panel?.frame
        return AgentPaneSessionInfoDebugState(
            nativeHost: model.sessionInfo.announced == true,
            open: info?.open == true,
            panel: panelFrame.map(AgentPaneSessionInfoDebugRect.init),
            page: AgentPaneSessionInfoDebugRect(pageFrame),
            top: info.map { $0.top },
            foot: info?.foot,
            zoom: max(0.25, webView.pageZoom),
            sectionCount: info?.sections.count ?? 0,
            flipped: isFlipped,
        )
    }

    /// Reads the real header control after the scene's click. The click path is the same one a
    /// person uses; this only verifies the resulting aria state before taking a still.
    public func debugSessionInfoHeaderPressed() async -> Bool {
        let script = "return document.querySelector('button.acpmux-session-info-toggle')?.getAttribute('aria-pressed') === 'true';"
        return (try? await callPageScript(script)) as? Bool ?? false
    }

    /// Sends one of the page-owned panel actions through the same bridge as a native row click.
    /// DEBUG capture tours use this to fold a section without adding a second policy path.
    @discardableResult
    public func debugSessionInfoAction(_ id: String) -> Bool {
        guard !id.isEmpty, let panel = model.sessionInfo.panel else { return false }
        panel.store.act(id)
        return true
    }
}
#endif
