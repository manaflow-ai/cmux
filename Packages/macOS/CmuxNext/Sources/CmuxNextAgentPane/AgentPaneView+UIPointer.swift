import CmuxNextDesign
import CmuxNextPages

/// The page-side half of the cmux NEXT own-window picker. It is deliberately
/// tiny and isolated to the page's own main frame; the native controller owns
/// the screenshot, redaction boundary and composer delivery.
extension AgentPaneView {
    /// Installs or removes the debug picker in this pane's document.
    public func setUiPointerInspector(_ enabled: Bool) {
        page?.evaluate(enabled ? Self.uiPointerScript : Self.uiPointerStopScript)
        if page == nil { webView.evaluateJavaScript(enabled ? Self.uiPointerScript : Self.uiPointerStopScript, completionHandler: nil) }
    }

    /// Runs a picker operation in whichever engine currently draws this pane.
    public func evaluateUiPointer(_ script: String) {
        if let page { page.evaluate(script) } else { webView.evaluateJavaScript(script, completionHandler: nil) }
    }

    /// View points per CSS pixel for the page currently drawing this pane.
    public var uiPointerPageZoom: Double {
        guard let page else { return webView.pageZoom * webView.magnification }
        return page.showsChromium
            ? Double(DesignSettings.shared.uiScale) * page.additionalZoom
            : page.webKitView.pageZoom * page.webKitView.magnification
    }

    private static let uiPointerStopScript = "globalThis.__cmuxUiPointer?.stop?.();"
    private static let uiPointerScript = #"""
    (() => {
      const post = (params) => {
        try { globalThis.__cmuxUiPointerPost?.(params); } catch (_) {}
      };
      const bounded = (value, limit) => String(value || "").slice(0, limit);
      const selector = (element) => {
        if (element.id) return `#${CSS.escape(element.id)}`;
        const testid = element.getAttribute("data-testid");
        if (testid) return `${element.localName}[data-testid="${CSS.escape(testid)}"]`;
        const aria = element.getAttribute("aria-label");
        if (aria) return `${element.localName}[aria-label="${CSS.escape(aria)}"]`;
        return element.localName || "element";
      };
      const inspect = (element) => {
        if (!element || element === overlayHost || overlayHost?.contains(element)) return null;
        const rect = element.getBoundingClientRect();
        const computed = getComputedStyle(element);
        const source = element.closest("[data-cmux-source]")?.getAttribute("data-cmux-source") || null;
        const component = element.closest("[data-cmux-component]")?.getAttribute("data-cmux-component") || null;
        const styles = {};
        for (const key of ["display", "position", "width", "height", "margin", "padding", "font-family", "font-size", "font-weight", "line-height", "color", "background-color", "border-radius"]) styles[key] = bounded(computed.getPropertyValue(key), 160);
        return { selector: selector(element), tag_name: element.localName || "element", text_content: bounded(element.innerText, 2000), dom_snippet: bounded(element.outerHTML, 2400), component, source_location: source, bounds: {x: rect.x, y: rect.y, width: rect.width, height: rect.height}, viewport: {width: innerWidth, height: innerHeight}, computed_styles: styles };
      };
      let overlayHost = null;
      let overlay = null;
      const ensure = () => {
        if (overlayHost?.isConnected) return;
        overlayHost = document.createElement("div");
        overlayHost.style.cssText = "all:initial;position:fixed;inset:0;pointer-events:none;z-index:2147483647";
        overlay = document.createElement("div");
        overlay.style.cssText = "position:fixed;display:none;pointer-events:none;box-sizing:border-box;border:2px solid #0a84ff;background:rgba(10,132,255,.12);border-radius:3px";
        overlayHost.append(overlay); document.documentElement.append(overlayHost);
      };
      const at = (x, y) => { ensure(); overlay.style.display = "none"; const element = document.elementFromPoint(x, y); if (!element || overlayHost.contains(element)) return null; const rect = element.getBoundingClientRect(); overlay.style.display = "block"; overlay.style.left = `${rect.x}px`; overlay.style.top = `${rect.y}px`; overlay.style.width = `${rect.width}px`; overlay.style.height = `${rect.height}px`; return element; };
      globalThis.__cmuxUiPointer?.stop?.();
      const move = (event) => at(event.clientX, event.clientY);
      document.addEventListener("mousemove", move, true);
      globalThis.__cmuxUiPointer = { highlight(x, y) { at(Number(x), Number(y)); }, pick(x, y) { const element = at(Number(x), Number(y)); const value = inspect(element); if (value) post(value); }, hide() { if (overlay) overlay.style.display = "none"; }, stop() { document.removeEventListener("mousemove", move, true); overlayHost?.remove(); overlayHost = null; overlay = null; } };
    })();
    """#
}
