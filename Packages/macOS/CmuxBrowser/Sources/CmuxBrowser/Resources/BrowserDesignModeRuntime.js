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
  const selectorAttributes = new Set(["id", "class", ...preferredAttributes]);
  const maxSnapshotCharacters = 128 * 1024;
  const maxTextCharacters = 16 * 1024;
  const maxTextNodeCount = 512;
  const maxSelectorCharacters = 2048;
  const maxSelectorValueCharacters = 160;
  const maxStyleValueCharacters = 512;
  const maxSnippetCharacters = 2400;
  const maxSelectionRecoveryAttempts = 8;
  const redactedValue = "<redacted>";
  const sensitiveNamePattern = /(?:^|[-_:])(api[-_]?key|auth|authorization|credential|csrf|password|passwd|secret|session|token)(?:$|[-_:])/i;
  const sensitiveAutocompletePattern = /(?:current-password|new-password|one-time-code|cc-number|cc-csc)/i;
  const voidElements = new Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]);

  let enabled = false;
  let revision = 0;
  let selectedElement = null;
  let selectedBaseline = null;
  let selectedIdentity = null;
  let hoveredElement = null;
  let overlayHost = null;
  let overlay = null;
  let observer = null;
  let refreshScheduled = false;
  let selectionIdentityNeedsRefresh = false;
  let selectionRecoveryFrame = 0;
  let selectionRecoveryAttemptsRemaining = 0;
  let overlayFrame = 0;
  let captureHidden = false;
  const edits = new Map();
  const styleOriginals = new Map();
  const textOriginals = new Map();

  const number = (value) => {
    const parsed = Number.parseFloat(String(value || "0"));
    return Number.isFinite(parsed) ? parsed : 0;
  };

  const bounded = (value, limit) => {
    const string = String(value ?? "");
    if (string.length <= limit) return string;
    return `${string.slice(0, Math.max(0, limit - 1))}…`;
  };

  const hasSensitiveName = (value) => sensitiveNamePattern.test(
    String(value || "").replace(/([a-z0-9])([A-Z])/g, "$1-$2"),
  );

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
    if (!selector || selector.length > maxSelectorCharacters) return false;
    try {
      const matches = document.querySelectorAll(selector);
      return matches.length === 1 && matches[0] === element;
    } catch (_) {
      return false;
    }
  };

  const classSelector = (element) => {
    const classes = [];
    for (const value of element.classList || []) {
      if (value.length > 0 && value.length <= 48
          && !/^(active|selected|hover|focus|open|closed|disabled)$/i.test(value)) {
        classes.push(value);
        if (classes.length === 3) break;
      }
    }
    if (!classes.length) return "";
    return `${element.localName}${classes.map((value) => `.${cssEscape(value)}`).join("")}`;
  };

  const structuralSelector = (element) => {
    const parts = [];
    let current = element;
    while (current && current.nodeType === 1 && parts.length < 7) {
      let part = current.localName || "*";
      if (current.id && current.id.length <= maxSelectorValueCharacters) {
        part = `#${cssEscape(current.id)}`;
        parts.unshift(part);
        break;
      }
      const stableClass = classSelector(current);
      if (stableClass) part = stableClass;
      const parent = current.parentElement;
      if (parent) {
        let matchingSiblingCount = 0;
        let matchingIndex = 0;
        for (const sibling of parent.children) {
          if (sibling.localName !== current.localName) continue;
          matchingSiblingCount += 1;
          if (sibling === current) matchingIndex = matchingSiblingCount;
        }
        if (matchingSiblingCount > 1) part += `:nth-of-type(${matchingIndex})`;
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
    if (element.id && element.id.length <= maxSelectorValueCharacters) {
      candidates.push(`#${cssEscape(element.id)}`);
    }
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
      if (unique.length === 6) break;
    }
    return unique;
  };

  const isSensitiveElement = (element) => {
    if (!element || element.nodeType !== 1) return false;
    if (["script", "style"].includes(element.localName)) return true;
    if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement) return true;
    const autocomplete = String(element.getAttribute?.("autocomplete") || "");
    if (sensitiveAutocompletePattern.test(autocomplete)) return true;
    return hasSensitiveName(element.getAttribute?.("name")) || hasSensitiveName(element.id);
  };

  const sanitizedAttributeValue = (element, attribute) => {
    const name = String(attribute.name || "");
    const value = String(attribute.value || "");
    if (hasSensitiveName(name)
        || (isSensitiveElement(element)
          && !["id", "name", "type", "autocomplete", "class", "role", "aria-label"].includes(name.toLowerCase()))
        || /(?:token|secret|password|passwd|credential|authorization|api[-_]?key)\s*[:=]/i.test(value)) {
      return redactedValue;
    }
    return value;
  };

  const hasSensitiveAncestor = (node, root) => {
    let current = node.parentElement;
    while (current) {
      if (isSensitiveElement(current)) return true;
      if (current === root) return false;
      current = current.parentElement;
    }
    return false;
  };

  const textValue = (element) => String(element.textContent || "");

  const boundedTextValue = (element) => {
    if (isSensitiveElement(element)) return redactedValue;
    const parts = [];
    let remaining = maxTextCharacters;
    let visited = 0;
    const walker = document.createTreeWalker(element, 4);
    while (remaining > 0 && visited < maxTextNodeCount) {
      const node = walker.nextNode();
      if (!node) break;
      visited += 1;
      if (hasSensitiveAncestor(node, element)) continue;
      const value = bounded(node.nodeValue, remaining);
      parts.push(value);
      remaining -= value.length;
    }
    return parts.join("");
  };

  const textIsEditable = (element) => {
    if (isSensitiveElement(element)) return false;
    if (element.childElementCount !== 0
        || ["html", "body", "script", "style"].includes(element.localName)) return false;
    let length = 0;
    let visited = 0;
    for (const node of element.childNodes || []) {
      visited += 1;
      if (visited > maxTextNodeCount) return false;
      if (node.nodeType !== 3) continue;
      length += node.nodeValue?.length || 0;
      if (length > maxTextCharacters) return false;
    }
    return true;
  };

  const identityFor = (element) => {
    const childTags = [];
    for (const child of element.children || []) {
      childTags.push(child.localName || "");
      if (childTags.length === 16) break;
    }
    const parent = element.parentElement;
    return [
      element.namespaceURI || "",
      element.localName || "",
      bounded(element.getAttribute?.("role"), maxSelectorValueCharacters),
      bounded(element.getAttribute?.("type"), maxSelectorValueCharacters),
      String(element.childElementCount || 0),
      childTags.join(","),
      parent?.namespaceURI || "",
      parent?.localName || "",
      bounded(parent?.id, maxSelectorValueCharacters),
      bounded(parent?.getAttribute?.("role"), maxSelectorValueCharacters),
    ].join("|");
  };

  const escapedMarkup = (value) => String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");

  const boundedSnippet = (element) => {
    const parts = [];
    let remaining = maxSnippetCharacters;
    const append = (value) => {
      if (remaining <= 0) return;
      const string = String(value);
      if (string.length <= remaining) {
        parts.push(string);
        remaining -= string.length;
      } else {
        parts.push(remaining === 1 ? "…" : `${string.slice(0, remaining - 1)}…`);
        remaining = 0;
      }
    };
    const visit = (node, depth) => {
      if (remaining <= 0) return;
      if (node.nodeType === 3) {
        append(escapedMarkup(bounded(node.nodeValue, Math.min(remaining, maxTextCharacters))));
        return;
      }
      if (node.nodeType !== 1) return;
      const tag = node.localName || "element";
      append(`<${tag}`);
      for (const attribute of node.attributes || []) {
        if (remaining <= 0) break;
        const value = escapedMarkup(bounded(sanitizedAttributeValue(node, attribute), Math.min(remaining, 512)));
        append(` ${attribute.name}="${value}"`);
      }
      append(">");
      if (voidElements.has(tag)) return;
      if (isSensitiveElement(node)) {
        append(redactedValue);
      } else if (depth < 5) {
        for (const child of node.childNodes || []) visit(child, depth + 1);
      } else if (node.childNodes?.length) {
        append("…");
      }
      append(`</${tag}>`);
    };
    visit(element, 0);
    return parts.join("");
  };

  const computedStylesFor = (element) => {
    const computed = getComputedStyle(element);
    const result = {};
    for (const property of capturedStyleProperties) {
      result[property] = bounded(computed.getPropertyValue(property).trim(), maxStyleValueCharacters);
    }
    return result;
  };

  const canonicalStyleValue = (property, value) => {
    const style = document.createElement("span").style;
    style.setProperty(property, value, "important");
    const canonical = style.getPropertyValue(property);
    return canonical && style.getPropertyPriority(property) === "important"
      ? bounded(canonical, maxStyleValueCharacters)
      : null;
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
      text_content: boundedTextValue(element),
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

  const snapshot = () => {
    const value = {
      revision,
      enabled,
      selection: selectionSnapshot(),
      edits: Array.from(edits.values()),
      css_diff: cssDiff(),
    };
    try {
      if (JSON.stringify(value).length <= maxSnapshotCharacters) return value;
    } catch (_) {}
    return { revision, enabled, selection: null, edits: [], css_diff: "" };
  };

  const emit = () => {
    const value = snapshot();
    try {
      handler?.postMessage({ type: "snapshot", snapshot: value });
    } catch (_) {}
    return value;
  };

  const resolveSelectedElement = (allowRecovery = false) => {
    if (!selectedBaseline) return null;
    if (selectedElement?.isConnected) return selectedElement;
    if (!allowRecovery) return null;
    for (const selector of selectedBaseline.selectors) {
      try {
        const candidates = document.querySelectorAll(selector);
        if (candidates.length === 1 && identityFor(candidates[0]) === selectedIdentity) {
          selectedElement = candidates[0];
          return candidates[0];
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
    if (textOriginals.has(element)) return true;
    if (!textIsEditable(element)) return false;
    const value = textValue(element);
    if (value.length > maxTextCharacters) return false;
    textOriginals.set(element, { value });
    return true;
  };

  const restoreText = () => {
    for (const [element, original] of textOriginals) {
      element.textContent = original.value;
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
    element.textContent = textValue.value;
    textOriginals.delete(element);
  };

  const applyText = (element, value) => {
    if (!rememberTextOriginal(element)) return false;
    if (element.textContent !== value) element.textContent = value;
    return true;
  };

  const applyEditsTo = (element) => {
    for (const edit of edits.values()) {
      if (edit.kind === "style") {
        rememberStyleOriginal(element, edit.property);
        if (element.style.getPropertyValue(edit.property) !== edit.value
            || element.style.getPropertyPriority(edit.property) !== "important") {
          element.style.setProperty(edit.property, edit.value, "important");
        }
      } else if (edit.kind === "text") {
        if (!applyText(element, edit.value)) edits.delete(edit.id);
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

  const refreshAfterMutation = (emitRecoveredSelection = false) => {
    refreshScheduled = false;
    let identityChanged = false;
    if (selectionIdentityNeedsRefresh && selectedElement?.isConnected && selectedBaseline) {
      const selectors = selectorsFor(selectedElement);
      if (!selectors.length) {
        restoreAll();
        selectedElement = null;
        selectedBaseline = null;
        selectedIdentity = null;
        hoveredElement = null;
        selectionIdentityNeedsRefresh = false;
        selectionRecoveryAttemptsRemaining = 0;
        cancelSelectionRecovery();
        revision += 1;
        emit();
        scheduleOverlayRefresh();
        return;
      }
      identityChanged = selectors[0] !== selectedBaseline.selector
        || selectors.length !== selectedBaseline.selectors.length
        || selectors.some((selector, index) => selector !== selectedBaseline.selectors[index]);
      selectedBaseline = { ...selectedBaseline, selector: selectors[0], selectors };
    }
    selectionIdentityNeedsRefresh = false;
    const previous = selectedElement;
    const current = resolveSelectedElement(true);
    if (previous && previous !== current) restoreAndForgetElement(previous);
    if (current) {
      applyEditsTo(current);
      selectedIdentity = identityFor(current);
      selectionRecoveryAttemptsRemaining = 0;
    } else if (previous) {
      selectionRecoveryAttemptsRemaining = maxSelectionRecoveryAttempts;
    }
    if (previous !== current || identityChanged || (emitRecoveredSelection && current)) {
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

  const cancelSelectionRecovery = () => {
    if (selectionRecoveryFrame) cancelAnimationFrame(selectionRecoveryFrame);
    selectionRecoveryFrame = 0;
  };

  const scheduleSelectionRecovery = () => {
    if (selectionRecoveryFrame || selectionRecoveryAttemptsRemaining <= 0) return;
    if (overlayFrame) cancelAnimationFrame(overlayFrame);
    overlayFrame = 0;
    selectionRecoveryFrame = requestAnimationFrame(() => {
      selectionRecoveryFrame = 0;
      if (!enabled || !selectedBaseline) return;
      selectionRecoveryAttemptsRemaining -= 1;
      refreshAfterMutation(true);
    });
  };

  const nodeContains = (container, candidate) => container === candidate
    || (typeof container?.contains === "function" && container.contains(candidate));

  const directChildOnPath = (ancestor, descendant) => {
    let current = descendant;
    while (current?.parentNode && current.parentNode !== ancestor) current = current.parentNode;
    return current?.parentNode === ancestor ? current : null;
  };

  const mutationCanRestoreSelection = (mutation) => {
    const selectedTag = selectedBaseline?.tag_name;
    if (!selectedTag) return false;
    if (mutation.type === "attributes") {
      return selectorAttributes.has(mutation.attributeName || "")
        && mutation.target?.localName === selectedTag;
    }
    if (mutation.type !== "childList") return false;
    return [...mutation.addedNodes, ...mutation.removedNodes]
      .some((node) => node.nodeType === 1 && node.localName === selectedTag);
  };

  const mutationTouchesSelection = (mutation) => {
    const selected = selectedElement;
    if (!selectedBaseline) return false;
    if (!selected) return mutationCanRestoreSelection(mutation);
    if (mutation.type === "characterData") return nodeContains(selected, mutation.target);
    if (mutation.type === "attributes") {
      if (mutation.target === selected && mutation.attributeName === "style") return true;
      if (!selectorAttributes.has(mutation.attributeName || "")) return false;
      if (mutation.target === selected || nodeContains(mutation.target, selected)) {
        selectionIdentityNeedsRefresh = true;
        return true;
      }
      return false;
    }
    if (mutation.type !== "childList") return false;
    if (nodeContains(selected, mutation.target)) return true;
    for (const node of mutation.removedNodes) {
      if (nodeContains(node, selected)) return true;
    }
    const pathChild = directChildOnPath(mutation.target, selected);
    if (!pathChild || pathChild.nodeType !== 1) return false;
    for (const node of [...mutation.addedNodes, ...mutation.removedNodes]) {
      if (node.nodeType === 1 && node.localName === pathChild.localName) {
        selectionIdentityNeedsRefresh = true;
        return true;
      }
    }
    return false;
  };

  const onMutations = (mutations) => {
    if (!selectedElement && selectedBaseline) {
      if (mutations.some(mutationCanRestoreSelection)) scheduleSelectionRecovery();
      return;
    }
    let touchesSelection = false;
    for (const mutation of mutations) {
      if (mutationTouchesSelection(mutation)) touchesSelection = true;
    }
    if (touchesSelection) scheduleMutationRefresh();
  };

  const selectElement = (element) => {
    if (!element || element === overlayHost || overlayHost?.contains(element)) return snapshot();
    cancelSelectionRecovery();
    if (selectedElement === element && selectedBaseline) {
      hoveredElement = null;
      scheduleOverlayRefresh();
      return snapshot();
    }
    const validatedBaseline = baselineFor(element);
    if (!validatedBaseline) return snapshot();
    if (selectedElement !== element && edits.size) restoreAll();
    const baseline = element.isConnected ? baselineFor(element) || validatedBaseline : validatedBaseline;
    selectedElement = element;
    selectedBaseline = baseline;
    selectedIdentity = identityFor(element);
    selectionIdentityNeedsRefresh = false;
    selectionRecoveryAttemptsRemaining = 0;
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
    selectedIdentity = null;
    selectionIdentityNeedsRefresh = false;
    selectionRecoveryAttemptsRemaining = 0;
    cancelSelectionRecovery();
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
    observer = new MutationObserver(onMutations);
    observer.observe(document.documentElement, {
      childList: true,
      subtree: true,
      characterData: true,
      attributes: true,
      attributeFilter: ["id", "class", "style", ...preferredAttributes],
    });
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
    cancelSelectionRecovery();
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
      selectedIdentity = null;
      selectionIdentityNeedsRefresh = false;
      selectionRecoveryAttemptsRemaining = 0;
      cancelSelectionRecovery();
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
      value = bounded(String(value ?? "").trim(), maxStyleValueCharacters);
      const element = resolveSelectedElement();
      if (!element || !styleProperties.has(property)) return snapshot();
      if (!value) return api.revert(`style:${property}`);
      value = canonicalStyleValue(property, value);
      if (!value) return snapshot();
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
        value: bounded(String(value ?? ""), maxTextCharacters),
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
      // Force style/layout synchronization before WebKit's snapshot callback;
      // requestAnimationFrame can stop entirely for a hidden or navigating document.
      document.documentElement.getBoundingClientRect();
      return snapshot();
    },

    finishCapture() {
      captureHidden = false;
      scheduleOverlayRefresh();
      return snapshot();
    },
  };

  globalThis.__cmuxDesignMode = api;
})();
