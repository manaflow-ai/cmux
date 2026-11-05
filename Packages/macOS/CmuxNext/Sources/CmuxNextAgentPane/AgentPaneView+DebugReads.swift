#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
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
          animations_pending: animationsPending
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
            return .object(members)
        } catch {
            return .object(["pane": .string(pane), "error": .string(String(describing: error))])
        }
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

    /// `debug.agent_pane menu_item`: the pane's own right-click menu, as WebKit would ask for it on
    /// empty space at the pane's centre, with the row titled `title` chosen (a capture can't open a
    /// real context menu): the rows run what a person's choice runs.
    public func debugRunMenuItem(title: String, pane: String) -> JSONValue {
        let menu = NSMenu()
        editContextMenu(menu)
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else {
            return .object(["pane": .string(pane), "error": .string("no row titled \(title)"), "rows": .array(titles.map(JSONValue.string))])
        }
        if let window {
            let centre = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            lastContextMenu = (window.convertPoint(toScreen: centre), ProcessInfo.processInfo.systemUptime)
        }
        let ran = NSApp.sendAction(action, to: item.target, from: item)
        return .object(["pane": .string(pane), "ran": .bool(ran), "rows": .array(titles.map(JSONValue.string))])
    }
}
#endif
