#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
public import CmuxNextSettings
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
            zoom: max(0.25, uiPointerPageZoom),
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

    /// `debug.agent_pane` `session_info_action` (`id`): ``debugSessionInfoAction(_:)``'s reply.
    public func debugSessionInfoAction(_ params: [String: JSONValue], pane: String) -> JSONValue {
        guard let id = params["id"]?.stringValue else {
            return .object(["pane": .string(pane), "error": .string("pass id")])
        }
        let sent = debugSessionInfoAction(id)
        return .object(["pane": .string(pane), "id": .string(id), "sent": .bool(sent)])
    }

    /// Opens Session Info with `click`, the real header click a person makes (the capture scene's
    /// `debug.agent_pane` click on "Session Info").
    public func debugOpenSessionInfo(pane: String, click: @MainActor () async -> JSONValue) async -> JSONValue {
        guard await debugSessionInfoHeaderPressed() else { return await click() }
        // Showcase state can retain an open toggle across scene renders. Close it with
        // the real header click first, then click the same control again to prove opening works.
        let close = await click()
        let open = await click()
        return .object(["pane": .string(pane), "initial_pressed": .bool(true), "close": close, "open": open])
    }

    /// Whether native Session Info settled open at full length below the header, with the capture
    /// scene's report. `settle` waits display frames until its condition holds and returns the ms
    /// it first held (nil at its deadline) with the frame stats; `windowWidth` is read after it.
    public func debugSessionInfoReadiness(
        pane: String,
        windowWidth: @MainActor () -> Double,
        settle: @MainActor (_ until: @escaping () -> Bool) async -> (ms: Double?, frames: JSONValue),
    ) async -> (ready: Bool, report: JSONValue) {
        // The page click has already returned after its event report. Read the toggle once, then
        // let display frames settle the AppKit panel geometry; no timer or polling loop is needed.
        let togglePressed = await debugSessionInfoHeaderPressed()
        let settled = await settle { [weak self] in self?.debugSessionInfoState.ready == true }
        let state = debugSessionInfoState
        let report: JSONValue = .object([
            "pane": .string(pane),
            "native_host": .bool(state.nativeHost),
            "open": .bool(state.open),
            "visible": .bool(state.visible),
            "frame_ready": .bool(state.frameReady),
            "full_length": .bool(state.foot == nil),
            "ready": .bool(state.ready),
            "header_toggle_pressed": .bool(togglePressed),
            "section_count": .number(Double(state.sectionCount)),
            "panel": state.panel?.json ?? .null,
            "page": state.page?.json ?? .null,
            "top": state.top.map { .number($0) } ?? .null,
            "foot": state.foot.map { .number($0) } ?? .null,
            "zoom": .number(state.zoom),
            "flipped": .bool(state.flipped),
            "window_width": .number(windowWidth()),
            "settled_ms": settled.ms.map { .number($0) } ?? .null,
            "frames": settled.frames,
        ])
        return (settled.ms != nil && state.ready && state.foot == nil && togglePressed, report)
    }
}

extension AgentPaneSessionInfoDebugState {
    /// Keep the capture in the wide-gutter state: the native panel then reaches the pane's 8 px
    /// foot instead of stopping above the composer. WindowController clamps this to the capture
    /// screen when its visible frame is narrower.
    @MainActor public static func widenCaptureWindow(_ window: NSWindow?) {
        guard let window else { return }
        let frame = window.frame
        let width = max(frame.width, 1_500)
        let height = max(frame.height, 850)
        guard width != frame.width || height != frame.height else { return }
        window.setFrame(CGRect(x: frame.minX, y: frame.minY, width: width, height: height), display: true)
    }
}

extension AgentPaneSessionInfoDebugRect {
    var json: JSONValue {
        .object(["x": .number(x), "y": .number(y), "width": .number(width), "height": .number(height)])
    }
}
#endif
