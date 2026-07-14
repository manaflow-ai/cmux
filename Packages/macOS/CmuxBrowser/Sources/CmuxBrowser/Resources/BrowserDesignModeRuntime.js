(() => {
  "use strict";

  if (globalThis.__cmuxDesignMode) return;

  const handler = globalThis.webkit?.messageHandlers?.cmuxDesignMode;
  const styleProperties = new Set([
    "width", "height",
    "margin-top", "margin-right", "margin-bottom", "margin-left",
    "padding-top", "padding-right", "padding-bottom", "padding-left",
    "font-family", "font-size", "font-weight", "line-height",
    "color", "background-color", "border-color", "border-radius",
  ]);
  const capturedStyleProperties = [
    "display", "position", "box-sizing", "width", "height",
    "margin-top", "margin-right", "margin-bottom", "margin-left",
    "padding-top", "padding-right", "padding-bottom", "padding-left",
    "font-family", "font-size", "font-weight", "line-height",
    "color", "background-color", "border-color", "border-width", "border-radius",
  ];
  const preferredAttributes = ["data-testid", "data-test", "data-qa", "aria-label", "name"];

  let enabled = false;
  let revision = 0;
  let selectedElement = null;
  let selectedBaseline = null;
  let hoveredElement = null;
  let overlayHost = null;
  let overlay = null;
  let observer = null;
  let refreshScheduled = false;
  let overlayFrame = 0;
  let captureHidden = false;
  const edits = new Map();
  const styleOriginals = new Map();
  const textOriginals = new Map();

  const number = (value) => {
    const parsed = Number.parseFloat(String(value || "0"));
    return Number.isFinite(parsed) ? parsed : 0;
  };

  const cssEscape = (value) => {
    if (globalThis.CSS && typeof globalThis.CSS.escape === "function") {
      return globalThis.CSS.escape(String(value));
    }
    return String(value).replace(/[^a-zA-Z0-9_-]/g, (character) => `\\${character}`);
  };

  const attributeValue = (value) => String(value)
    .replace(/\\/g, "\\\\")
    .replace(/"/g, "\\\"")
    .replace(/\n/g, "\\a ")
    .replace(/\r/g, "");

  const isUniqueFor = (selector, element) => {
    if (!selector) return false;
    try {
      const matches = document.querySelectorAll(selector);
      return matches.length === 1 && matches[0] === element;
    } catch (_) {
      return false;
    }
  };

  const classSelector = (element) => {
    const classes = Array.from(element.classList || [])
      .filter((value) => value.length > 0 && value.length <= 48)
      .filter((value) => !/^(active|selected|hover|focus|open|closed|disabled)$/i.test(value))
      .slice(0, 3);
    if (!classes.length) return "";
    return `${element.localName}${classes.map((value) => `.${cssEscape(value)}`).join("")}`;
  };

  const structuralSelector = (element) => {
    const parts = [];
    let current = element;
    while (current && current.nodeType === 1 && parts.length < 7) {
      let part = current.localName || "*";
      if (current.id) {
        part = `#${cssEscape(current.id)}`;
        parts.unshift(part);
        break;
      }
      const stableClass = classSelector(current);
      if (stableClass) part = stableClass;
      const parent = current.parentElement;
      if (parent) {
        const siblings = Array.from(parent.children).filter((candidate) => candidate.localName === current.localName);
        if (siblings.length > 1) part += `:nth-of-type(${siblings.indexOf(current) + 1})`;
      }
      parts.unshift(part);
      const candidate = parts.join(" > ");
      if (isUniqueFor(candidate, element)) return candidate;
      current = parent;
    }
    return parts.join(" > ");
  };

  const selectorsFor = (element) => {
    const candidates = [];
    if (element.id) candidates.push(`#${cssEscape(element.id)}`);
    for (const name of preferredAttributes) {
      const value = element.getAttribute?.(name);
      if (!value || value.length > 160) continue;
      candidates.push(`${element.localName}[${name}="${attributeValue(value)}"]`);
      candidates.push(`[${name}="${attributeValue(value)}"]`);
    }
    const classes = classSelector(element);
    if (classes) candidates.push(classes);
    candidates.push(structuralSelector(element));

    const unique = [];
    for (const candidate of candidates) {
      if (!candidate || unique.includes(candidate)) continue;
      if (isUniqueFor(candidate, element)) unique.push(candidate);
    }
    if (!unique.length) {
      const fallback = structuralSelector(element);
      if (fallback) unique.push(fallback);
    }
    return unique;
  };

  const textValue = (element) => {
    if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement) {
      return String(element.value || "");
    }
    return String(element.textContent || "");
  };

  const textIsEditable = (element) => {
    if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement) return true;
    return element.childElementCount === 0 && !["html", "body", "script", "style"].includes(element.localName);
  };

  const boundedSnippet = (element) => {
    const html = String(element.outerHTML || "").replace(/\s+/g, " ").trim();
    return html.length <= 2400 ? html : `${html.slice(0, 2399)}…`;
  };

  const computedStylesFor = (element) => {
    const computed = getComputedStyle(element);
    const result = {};
    for (const property of capturedStyleProperties) {
      result[property] = computed.getPropertyValue(property).trim();
    }
    return result;
  };

  const rectFor = (element) => {
    const rect = element.getBoundingClientRect();
    return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
  };

  const baselineFor = (element) => {
    const selectors = selectorsFor(element);
    if (!selectors.length) return null;
    return {
      selector: selectors[0],
      selectors,
      tag_name: element.localName || "element",
      dom_snippet: boundedSnippet(element),
      text_content: textValue(element),
      text_editable: textIsEditable(element),
      computed_styles: computedStylesFor(element),
    };
  };

  const selectionSnapshot = () => {
    const element = resolveSelectedElement();
    if (!element || !selectedBaseline) return null;
    return {
      ...selectedBaseline,
      bounds: rectFor(element),
      viewport: { width: globalThis.innerWidth || 0, height: globalThis.innerHeight || 0 },
    };
  };

  const cssDiff = () => {
    if (!selectedBaseline) return "";
    const styleEdits = Array.from(edits.values()).filter((edit) => edit.kind === "style");
    if (!styleEdits.length) return "";
    const lines = [`${selectedBaseline.selector} {`];
    for (const edit of styleEdits) {
      lines.push(`-  ${edit.property}: ${edit.original_value || "<unset>"};`);
      lines.push(`+  ${edit.property}: ${edit.value};`);
    }
    lines.push("}");
    return lines.join("\n");
  };

  const snapshot = () => ({
    revision,
    enabled,
    selection: selectionSnapshot(),
    edits: Array.from(edits.values()),
    css_diff: cssDiff(),
  });

  const emit = () => {
    const value = snapshot();
    try {
      handler?.postMessage({ type: "snapshot", snapshot: value });
    } catch (_) {}
    return value;
  };

  const resolveSelectedElement = () => {
    if (!selectedBaseline) return null;
    if (selectedElement?.isConnected) return selectedElement;
    for (const selector of selectedBaseline.selectors) {
      try {
        const candidate = document.querySelector(selector);
        if (candidate) {
          selectedElement = candidate;
          return candidate;
        }
      } catch (_) {}
    }
    selectedElement = null;
    return null;
  };

  const rememberStyleOriginal = (element, property) => {
    let originals = styleOriginals.get(element);
    if (!originals) {
      originals = new Map();
      styleOriginals.set(element, originals);
    }
    if (!originals.has(property)) {
      originals.set(property, {
        value: element.style.getPropertyValue(property),
        priority: element.style.getPropertyPriority(property),
      });
    }
  };

  const restoreStyleProperty = (property) => {
    for (const [element, originals] of styleOriginals) {
      const original = originals.get(property);
      if (!original) continue;
      if (original.value) element.style.setProperty(property, original.value, original.priority);
      else element.style.removeProperty(property);
      originals.delete(property);
      if (!originals.size) styleOriginals.delete(element);
    }
  };

  const rememberTextOriginal = (element) => {
    if (textOriginals.has(element)) return;
    const input = element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement;
    textOriginals.set(element, { input, value: textValue(element) });
  };

  const restoreText = () => {
    for (const [element, original] of textOriginals) {
      if (original.input) {
        element.value = original.value;
        element.dispatchEvent(new Event("input", { bubbles: true }));
      } else {
        element.textContent = original.value;
      }
    }
    textOriginals.clear();
  };

  const restoreAndForgetElement = (element) => {
    const styleValues = styleOriginals.get(element);
    if (styleValues) {
      for (const [property, original] of styleValues) {
        if (original.value) element.style.setProperty(property, original.value, original.priority);
        else element.style.removeProperty(property);
      }
      styleOriginals.delete(element);
    }
    const textValue = textOriginals.get(element);
    if (!textValue) return;
    if (textValue.input) {
      element.value = textValue.value;
      element.dispatchEvent(new Event("input", { bubbles: true }));
    } else {
      element.textContent = textValue.value;
    }
    textOriginals.delete(element);
  };

  const applyText = (element, value) => {
    rememberTextOriginal(element);
    if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement) {
      if (element.value === value) return;
      element.value = value;
      element.dispatchEvent(new Event("input", { bubbles: true }));
      return;
    }
    if (element.textContent !== value) element.textContent = value;
  };

  const applyEditsTo = (element) => {
    for (const edit of edits.values()) {
      if (edit.kind === "style") {
        rememberStyleOriginal(element, edit.property);
        element.style.setProperty(edit.property, edit.value, "important");
      } else if (edit.kind === "text") {
        applyText(element, edit.value);
      }
    }
  };

  const restoreAll = () => {
    for (const property of new Set(Array.from(edits.values()).filter((edit) => edit.kind === "style").map((edit) => edit.property))) {
      restoreStyleProperty(property);
    }
    restoreText();
    edits.clear();
  };

  const box = (className, color) => {
    const element = document.createElement("div");
    element.className = className;
    Object.assign(element.style, {
      display: "none",
      position: "fixed",
      pointerEvents: "none",
      boxSizing: "border-box",
      background: color,
    });
    return element;
  };

  const createOverlay = () => {
    if (overlayHost?.isConnected) return;
    overlayHost = document.createElement("div");
    overlayHost.setAttribute("data-cmux-design-mode", "overlay");
    overlayHost.setAttribute("aria-hidden", "true");
    overlayHost.style.setProperty("all", "initial", "important");
    overlayHost.style.setProperty("position", "fixed", "important");
    overlayHost.style.setProperty("inset", "0", "important");
    overlayHost.style.setProperty("pointer-events", "none", "important");
    overlayHost.style.setProperty("z-index", "2147483647", "important");
    const shadow = overlayHost.attachShadow({ mode: "closed" });

    const margin = box("margin", "rgba(246, 178, 107, 0.28)");
    const border = box("border", "rgba(255, 214, 102, 0.30)");
    const padding = box("padding", "rgba(131, 211, 124, 0.30)");
    const content = box("content", "rgba(91, 155, 213, 0.28)");
    content.style.outline = "2px solid rgb(64, 137, 245)";
    content.style.outlineOffset = "-1px";

    const badge = document.createElement("div");
    Object.assign(badge.style, {
      display: "none",
      position: "fixed",
      pointerEvents: "none",
      maxWidth: "min(520px, calc(100vw - 16px))",
      padding: "4px 7px",
      borderRadius: "5px",
      color: "white",
      background: "rgba(27, 31, 38, 0.96)",
      boxShadow: "0 2px 10px rgba(0, 0, 0, 0.28)",
      font: "600 11px/1.35 ui-monospace, SFMono-Regular, Menlo, monospace",
      whiteSpace: "nowrap",
      overflow: "hidden",
      textOverflow: "ellipsis",
    });

    shadow.append(margin, border, padding, content, badge);
    document.documentElement.appendChild(overlayHost);
    overlay = { margin, border, padding, content, badge };
  };

  const hideOverlay = () => {
    if (!overlay) return;
    for (const element of Object.values(overlay)) element.style.display = "none";
  };

  const place = (element, rect) => {
    element.style.display = "block";
    element.style.left = `${rect.x}px`;
    element.style.top = `${rect.y}px`;
    element.style.width = `${Math.max(0, rect.width)}px`;
    element.style.height = `${Math.max(0, rect.height)}px`;
  };

  const refreshOverlay = () => {
    overlayFrame = 0;
    if (!enabled || captureHidden) {
      hideOverlay();
      return;
    }
    createOverlay();
    const selected = resolveSelectedElement();
    const element = hoveredElement?.isConnected ? hoveredElement : selected;
    if (!element) {
      hideOverlay();
      return;
    }

    const rect = element.getBoundingClientRect();
    const computed = getComputedStyle(element);
    const margin = {
      top: number(computed.marginTop), right: number(computed.marginRight),
      bottom: number(computed.marginBottom), left: number(computed.marginLeft),
    };
    const border = {
      top: number(computed.borderTopWidth), right: number(computed.borderRightWidth),
      bottom: number(computed.borderBottomWidth), left: number(computed.borderLeftWidth),
    };
    const padding = {
      top: number(computed.paddingTop), right: number(computed.paddingRight),
      bottom: number(computed.paddingBottom), left: number(computed.paddingLeft),
    };

    place(overlay.margin, {
      x: rect.x - margin.left, y: rect.y - margin.top,
      width: rect.width + margin.left + margin.right,
      height: rect.height + margin.top + margin.bottom,
    });
    place(overlay.border, { x: rect.x, y: rect.y, width: rect.width, height: rect.height });
    place(overlay.padding, {
      x: rect.x + border.left, y: rect.y + border.top,
      width: rect.width - border.left - border.right,
      height: rect.height - border.top - border.bottom,
    });
    place(overlay.content, {
      x: rect.x + border.left + padding.left,
      y: rect.y + border.top + padding.top,
      width: rect.width - border.left - border.right - padding.left - padding.right,
      height: rect.height - border.top - border.bottom - padding.top - padding.bottom,
    });

    const selector = element === selected
      ? selectedBaseline?.selector || element.localName || "element"
      : (element.id ? `#${cssEscape(element.id)}` : classSelector(element) || element.localName || "element");
    overlay.badge.textContent = `${selector}  ${Math.round(rect.width)} × ${Math.round(rect.height)}`;
    overlay.badge.style.display = "block";
    const badgeHeight = overlay.badge.getBoundingClientRect().height || 24;
    overlay.badge.style.left = `${Math.max(8, Math.min(rect.x, globalThis.innerWidth - 220))}px`;
    overlay.badge.style.top = `${rect.y > badgeHeight + 8 ? rect.y - badgeHeight - 5 : rect.bottom + 5}px`;
  };

  const scheduleOverlayRefresh = () => {
    if (overlayFrame) return;
    overlayFrame = requestAnimationFrame(refreshOverlay);
  };

  const refreshAfterMutation = () => {
    refreshScheduled = false;
    const previous = selectedElement;
    const current = resolveSelectedElement();
    if (previous && previous !== current) restoreAndForgetElement(previous);
    if (current) applyEditsTo(current);
    if (previous !== current) {
      revision += 1;
      emit();
    }
    scheduleOverlayRefresh();
  };

  const scheduleMutationRefresh = () => {
    if (refreshScheduled) return;
    refreshScheduled = true;
    const enqueue = globalThis.queueMicrotask || ((work) => Promise.resolve().then(work));
    enqueue(refreshAfterMutation);
  };

  const selectElement = (element) => {
    if (!element || element === overlayHost || overlayHost?.contains(element)) return snapshot();
    if (selectedElement !== element && edits.size) restoreAll();
    const baseline = baselineFor(element);
    if (!baseline) return snapshot();
    selectedElement = element;
    selectedBaseline = baseline;
    hoveredElement = null;
    revision += 1;
    scheduleOverlayRefresh();
    return emit();
  };

  const onPointerMove = (event) => {
    if (!enabled || captureHidden) return;
    const candidate = document.elementFromPoint(event.clientX, event.clientY);
    if (!candidate || candidate === hoveredElement) return;
    hoveredElement = candidate;
    scheduleOverlayRefresh();
  };

  const onClick = (event) => {
    if (!enabled || captureHidden) return;
    const candidate = document.elementFromPoint(event.clientX, event.clientY) || event.target;
    if (!candidate) return;
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();
    selectElement(candidate);
  };

  const onKeyDown = (event) => {
    if (!enabled || captureHidden || event.key !== "Escape" || !selectedBaseline) return;
    event.preventDefault();
    event.stopPropagation();
    restoreAll();
    selectedElement = null;
    selectedBaseline = null;
    revision += 1;
    scheduleOverlayRefresh();
    emit();
  };

  const installListeners = () => {
    document.addEventListener("pointermove", onPointerMove, true);
    document.addEventListener("click", onClick, true);
    document.addEventListener("keydown", onKeyDown, true);
    globalThis.addEventListener("scroll", scheduleOverlayRefresh, true);
    globalThis.addEventListener("resize", scheduleOverlayRefresh, true);
    observer = new MutationObserver(scheduleMutationRefresh);
    observer.observe(document.documentElement, { childList: true, subtree: true, characterData: true });
  };

  const removeListeners = () => {
    document.removeEventListener("pointermove", onPointerMove, true);
    document.removeEventListener("click", onClick, true);
    document.removeEventListener("keydown", onKeyDown, true);
    globalThis.removeEventListener("scroll", scheduleOverlayRefresh, true);
    globalThis.removeEventListener("resize", scheduleOverlayRefresh, true);
    observer?.disconnect();
    observer = null;
    if (overlayFrame) cancelAnimationFrame(overlayFrame);
    overlayFrame = 0;
  };

  const api = {
    enable() {
      if (!enabled) {
        enabled = true;
        revision += 1;
        createOverlay();
        installListeners();
        scheduleOverlayRefresh();
      }
      return emit();
    },

    destroy() {
      if (enabled || selectedBaseline || edits.size || overlayHost) revision += 1;
      enabled = false;
      removeListeners();
      restoreAll();
      selectedElement = null;
      selectedBaseline = null;
      hoveredElement = null;
      overlayHost?.remove();
      overlayHost = null;
      overlay = null;
      captureHidden = false;
      const finalSnapshot = snapshot();
      try { delete globalThis.__cmuxDesignMode; } catch (_) { globalThis.__cmuxDesignMode = undefined; }
      return finalSnapshot;
    },

    snapshot,

    select(selector) {
      let element = null;
      try { element = document.querySelector(String(selector || "")); } catch (_) {}
      return element ? selectElement(element) : snapshot();
    },

    applyStyle(property, value) {
      property = String(property || "").trim().toLowerCase();
      value = String(value ?? "").trim();
      const element = resolveSelectedElement();
      if (!element || !styleProperties.has(property)) return snapshot();
      if (!value) return api.revert(`style:${property}`);
      const id = `style:${property}`;
      const previous = edits.get(id);
      const original = previous?.original_value
        ?? selectedBaseline?.computed_styles?.[property]
        ?? getComputedStyle(element).getPropertyValue(property).trim();
      edits.set(id, { id, kind: "style", property, original_value: original, value });
      applyEditsTo(element);
      revision += 1;
      scheduleOverlayRefresh();
      return emit();
    },

    applyText(value) {
      const element = resolveSelectedElement();
      if (!element || !selectedBaseline?.text_editable) return snapshot();
      const id = "text:text-content";
      edits.set(id, {
        id, kind: "text", property: "text-content",
        original_value: selectedBaseline.text_content,
        value: String(value ?? ""),
      });
      applyEditsTo(element);
      revision += 1;
      scheduleOverlayRefresh();
      return emit();
    },

    revert(id) {
      const edit = edits.get(String(id || ""));
      if (!edit) return snapshot();
      edits.delete(edit.id);
      if (edit.kind === "style") restoreStyleProperty(edit.property);
      else restoreText();
      const element = resolveSelectedElement();
      if (element) applyEditsTo(element);
      revision += 1;
      scheduleOverlayRefresh();
      return emit();
    },

    revertAll() {
      if (!edits.size) return snapshot();
      restoreAll();
      revision += 1;
      scheduleOverlayRefresh();
      return emit();
    },

    prepareCapture() {
      captureHidden = true;
      hideOverlay();
      return new Promise((resolve) => {
        requestAnimationFrame(() => requestAnimationFrame(() => resolve(snapshot())));
      });
    },

    finishCapture() {
      captureHidden = false;
      scheduleOverlayRefresh();
      return snapshot();
    },
  };

  globalThis.__cmuxDesignMode = api;
})();
