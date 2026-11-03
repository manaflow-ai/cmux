#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextSettings
import Foundation

/// `debug.agent_pane` reads of the chat page that the capture scenes and benches use (DEBUG
/// builds): its readiness for a still and the ACP Inspector toggle.
extension AgentPaneView {
    /// `debug.agent_pane readiness`: whether the page drew a transcript and a composer, and (with
    /// `waitForAnimations`, up to 1 s) whether its menus finished animating.
    public func debugReadiness(pane: String, waitForAnimations: Bool = false) async -> JSONValue {
        let script = """
        const bodyText = (document.body?.innerText || '').trim();
        const composer = document.querySelector('.acpmux-composer');
        const composerRect = composer?.getBoundingClientRect();
        const bodyRect = document.body?.getBoundingClientRect();
        const adoptionPaint = window.__cmuxSessionAdoptionPaint;
        const debug = window.cmuxAcpmuxDebug;
        const state = debug && typeof debug.chatState === 'function' ? debug.chatState() : {};
        const transcriptRows = Number(state.rows || 0) || document.querySelectorAll('.cv-worked, .cv-message, .cv-tool, .cv-turn-actions').length;
        const menus = [...document.querySelectorAll('.acpmux-menu, .acpmux-slash-menu')];
        const menuAnimations = menus.flatMap((node) => typeof node.getAnimations === 'function' ? node.getAnimations() : []);
        if (waitForAnimations && menuAnimations.length) {
          await Promise.race([
            Promise.all(menuAnimations.map((animation) => animation.finished.catch(() => undefined))),
            new Promise((resolve) => setTimeout(resolve, 1000))
          ]);
        }
        const animationsPending = menuAnimations.some((animation) => animation.playState === 'running');
        return JSON.stringify({
          body_text_length: bodyText.length,
          transcript_rows: transcriptRows,
          composer_visible: !!composer && !!composerRect && composerRect.width > 0 && composerRect.height > 0,
          composer_text_length: (composer?.innerText || '').trim().length,
          document_ready: document.readyState === 'complete',
          animations_pending: animationsPending,
          visibility_state: document.visibilityState,
          document_hidden: document.hidden,
          inner_width: window.innerWidth,
          inner_height: window.innerHeight,
          body_width: bodyRect?.width ?? 0,
          body_height: bodyRect?.height ?? 0,
          adoption_paint: adoptionPaint ?? null
        });
        """
        do {
            // The script reads `waitForAnimations` as an argument; without it every readiness call threw.
            let result = try await callPageScript(script, arguments: ["waitForAnimations": waitForAnimations])
            guard let text = result as? String,
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]),
                  let value = JSONValue(foundation: object),
                  case .object(var members) = value else {
                return .object(["pane": .string(pane), "error": .string("the page returned no readiness JSON")])
            }
            members["pane"] = .string(pane)
            members["native"] = .object([
                "holds_page_away": .bool(holdsPageAway),
                "model_has_painted": .bool(model.hasPainted),
                "page_reported_paint": .bool(model.pageReportedPaint),
                "loading_present": .bool(loadingView.superview != nil),
                "loading_hidden": .bool(loadingView.isHidden),
                "page_alpha": .number(Double(pageContent.alphaValue)),
                "page_frame_x": .number(Double(pageContent.frame.origin.x)),
                "page_frame_y": .number(Double(pageContent.frame.origin.y)),
                "page_frame_width": .number(Double(pageContent.frame.width)),
                "page_frame_height": .number(Double(pageContent.frame.height)),
                "pane_hidden": .bool(isHiddenOrHasHiddenAncestor),
                "window_visible": .bool(window?.isVisible == true),
                "window_occlusion_visible": .bool(window?.occlusionState.contains(.visible) == true),
                "engine": .string(engineName),
                "chromium_page_shown": .bool(debugChromiumPageShown)
            ])
            members["watchdog"] = debugPaintWatchdogSnapshot ?? .null
            return .object(members)
        } catch {
            return .object(["pane": .string(pane), "error": .string(String(describing: error))])
        }
    }

    /// Captures native presentation state synchronously before the loading watchdog reveals an
    /// unreported page. The snapshot is replaced on each watchdog reveal and never drives behavior.
    func captureDebugPaintWatchdogSnapshot() {
        debugPaintWatchdogSnapshot = .object([
            "holds_page_away": .bool(holdsPageAway),
            "model_has_painted": .bool(model.hasPainted),
            "page_reported_paint": .bool(model.pageReportedPaint),
            "loading_present": .bool(loadingView.superview != nil),
            "loading_hidden": .bool(loadingView.isHidden),
            "page_alpha": .number(Double(pageContent.alphaValue)),
            "page_frame_x": .number(Double(pageContent.frame.origin.x)),
            "page_frame_y": .number(Double(pageContent.frame.origin.y)),
            "page_frame_width": .number(Double(pageContent.frame.width)),
            "page_frame_height": .number(Double(pageContent.frame.height)),
            "pane_hidden": .bool(isHiddenOrHasHiddenAncestor),
            "window_visible": .bool(window?.isVisible == true),
            "window_occlusion_visible": .bool(window?.occlusionState.contains(.visible) == true),
            "engine": .string(engineName),
            "chromium_page_shown": .bool(debugChromiumPageShown)
        ])
    }

    /// `debug.agent_pane inspector`: calls the page bridge that Show ACP Inspector calls
    /// (``toggleInspector(open:)``) and reads back whether it is open.
    public func debugToggleInspector(open: Bool?, pane: String) async -> JSONValue {
        let script = """
            const bridge = window.cmuxAcpmuxBridge;
            return typeof bridge?.toggleInspector === "function" ? bridge.toggleInspector(open ?? undefined) : null;
            """
        do {
            let result = try await callPageScript(script, arguments: ["open": open.map { $0 as Any } ?? NSNull()])
            guard let isOpen = result as? Bool else {
                return .object(["pane": .string(pane), "error": .string("the page has no cmuxAcpmuxBridge.toggleInspector")])
            }
            return .object(["pane": .string(pane), "inspector_open": .bool(isOpen)])
        } catch {
            return .object(["pane": .string(pane), "error": .string(String(describing: error))])
        }
    }
}
#endif
