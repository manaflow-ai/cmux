#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextSettings
import Foundation
import QuartzCore

/// `debug.agent_pane {action: "resize_probe", step}` (DEBUG builds): the split-resize harness's page recorder
/// (scripts/ci/frame-pacing/split_resize.py) in a chat page, which `browser.page.eval` does not reach. It is the
/// probe page's recorder (browser_resize.py `PROBE_PAGE`): `[performance.timeOrigin + rAF timestamp, innerWidth,
/// innerHeight]` on every animation frame, in `window.__rz`.
extension AgentPaneView {
    private static let resizeProbeStart = """
        window.__rz = [];
        if (!window.__rzRunning) {
            window.__rzRunning = true;
            requestAnimationFrame(function frame(t) {
                if (window.__rz.length < 20000) window.__rz.push([performance.timeOrigin + t, innerWidth, innerHeight]);
                requestAnimationFrame(frame);
            });
        }
        return JSON.stringify({ started: true, width: innerWidth, height: innerHeight });
        """

    private static let resizeProbeRead = "return JSON.stringify({ frames: Array.isArray(window.__rz) ? window.__rz : [] });"

    /// `step`: `start` empties the record and starts the recorder once per page; `read` returns it as `frames`. Both
    /// return `clock`, this process's epoch (`epoch_ms`) and host time (`host_s`, CACurrentMediaTime) read together,
    /// so the harness puts a `debug.motion` trace's `t0_s` on the page's epoch clock.
    public func debugResizeProbe(step: String, pane: String) async -> JSONValue {
        guard step == "start" || step == "read" else {
            return .object(["pane": .string(pane), "error": .string("unknown step; use start or read")])
        }
        do {
            let result = try await callPageScript(step == "start" ? Self.resizeProbeStart : Self.resizeProbeRead)
            let clock: JSONValue = .object([
                "epoch_ms": .number(Date().timeIntervalSince1970 * 1_000),
                "host_s": .number(CACurrentMediaTime()),
            ])
            guard let text = result as? String,
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]),
                  case .object(var members)? = JSONValue(foundation: object) else {
                return .object(["pane": .string(pane), "error": .string("the page returned no resize_probe JSON")])
            }
            members["pane"] = .string(pane)
            members["clock"] = clock
            return .object(members)
        } catch {
            return .object(["pane": .string(pane), "error": .string(String(describing: error))])
        }
    }
}
#endif
