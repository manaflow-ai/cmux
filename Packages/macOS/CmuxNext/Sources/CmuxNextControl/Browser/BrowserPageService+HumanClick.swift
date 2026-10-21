import CmuxNextSettings
import Foundation

/// `browser.page.click` with human motion (plans/cmux-next/human-mouse-DESIGN.md):
/// one script measures the element and where the agent's pointer was, the
/// path is planned here, and one awaited script walks it with pointer and
/// mouse events (over/enter/out/leave as it crosses elements), rests,
/// presses, holds and releases. The page's events are script events, as
/// `el.click()` was; native input stays with the browser REPL.
extension BrowserPageService {
    static func humanClick(_ engine: any BrowserPageEngine, selector: String, path model: HumanPointerPath,
                           tab: Tab) async throws -> JSONValue {
        let measured = try await run(engine, .evaluate(BrowserPageScripts.clickMeasure(selector)), tab)["value"] ?? .null
        guard measured["error"] == nil, let at = measured["at"], let from = measured["from"],
              let x = at["x"]?.doubleValue, let y = at["y"]?.doubleValue,
              let w = at["w"]?.doubleValue, let h = at["h"]?.doubleValue,
              let fx = from["x"]?.doubleValue, let fy = from["y"]?.doubleValue else { return measured }
        let target = CGPoint(x: (x + w / 2).rounded(), y: (y + h / 2).rounded())
        let seed = UInt32.random(in: .min ... .max)
        let samples = model.plan(from: CGPoint(x: fx, y: fy), to: target, width: max(1, min(w, h)), seed: seed)
        let walk = BrowserPageScripts.clickWalk(selector, path: samples,
                                                dwellMs: model.pause(model.dwellMs, seed: seed &+ 1),
                                                holdMs: model.pause(model.holdMs, seed: seed &+ 2))
        let walked = try await run(engine, .evaluateAsync(walk), tab)["value"] ?? .null
        if walked["error"] != nil { return walked }
        return measured
    }
}

extension BrowserPageScripts {
    /// Scrolls the element into view and returns `{value, at, from}`: its
    /// rect and where the agent's pointer last was in this page (the
    /// viewport's middle the first time).
    static func clickMeasure(_ selector: String) -> String {
        wrap(find(selector) + """
        el.scrollIntoView({block: 'center'}); const at = cmuxAt(el);
        const from = window.__cmuxAgentPointer || { x: Math.round(innerWidth / 2), y: Math.round(innerHeight / 2) };
        return { value: true, at, from };
        """)
    }

    /// The awaited body that walks `path` (ms, CSS px), then clicks the element.
    static func clickWalk(_ selector: String, path: [HumanPointerPath.Sample], dwellMs: Double, holdMs: Double) -> String {
        let points = path.map { String(format: "{t:%.1f,x:%.0f,y:%.0f}", $0.t, $0.x, $0.y) }.joined(separator: ",")
        return find(selector) + """
        const path = [\(points)];
        const dwell = \(String(format: "%.0f", dwellMs)); const hold = \(String(format: "%.0f", holdMs));
        const wait = (ms) => new Promise((r) => setTimeout(r, Math.max(0, ms)));
        const opts = (x, y, extra) => Object.assign({ bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y,
          screenX: x + screenX, screenY: y + screenY, pointerId: 1, pointerType: 'mouse', isPrimary: true }, extra || {});
        const fire = (t, type, x, y, extra) => { if (!t) return; const P = type.startsWith('pointer') ? PointerEvent : MouseEvent;
          t.dispatchEvent(new P(type, opts(x, y, Object.assign(type.endsWith('enter') || type.endsWith('leave') ? { bubbles: false } : {}, extra)))); };
        let over = null; const start = performance.now();
        for (const p of path) {
          await wait(p.t - (performance.now() - start));
          const t = document.elementFromPoint(p.x, p.y) || document.body;
          if (t !== over) { fire(over, 'pointerout', p.x, p.y); fire(over, 'mouseout', p.x, p.y); fire(over, 'pointerleave', p.x, p.y); fire(over, 'mouseleave', p.x, p.y);
            fire(t, 'pointerover', p.x, p.y); fire(t, 'mouseover', p.x, p.y); fire(t, 'pointerenter', p.x, p.y); fire(t, 'mouseenter', p.x, p.y); over = t; }
          fire(t, 'pointermove', p.x, p.y); fire(t, 'mousemove', p.x, p.y);
          window.__cmuxAgentPointer = { x: p.x, y: p.y };
        }
        const last = path.at(-1); const hit = (el.contains(over) ? over : el);
        await wait(dwell);
        fire(hit, 'pointerdown', last.x, last.y, { button: 0, buttons: 1 }); fire(hit, 'mousedown', last.x, last.y, { button: 0, buttons: 1, detail: 1 });
        try { (el.closest('input,textarea,select,button,a,[tabindex],[contenteditable]') || el).focus({ preventScroll: true }); } catch (_) {}
        await wait(hold);
        fire(hit, 'pointerup', last.x, last.y, { button: 0, buttons: 0 }); fire(hit, 'mouseup', last.x, last.y, { button: 0, buttons: 0, detail: 1 });
        if (hit.isConnected) { hit.dispatchEvent(new MouseEvent('click', opts(last.x, last.y, { button: 0, detail: 1 }))); } else { el.click(); }
        return { value: true };
        """
    }
}
