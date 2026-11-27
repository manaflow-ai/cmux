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
  const urlBearingAttributes = new Set([
    "action", "cite", "data", "formaction", "href", "ping", "poster", "src", "srcset",
  ]);
  const maxSnapshotCharacters = 128 * 1024;
  const maxTextCharacters = 16 * 1024;
  const maxTextNodeCount = 512;
  const maxSelectorCharacters = 2048;
  const maxSelectorValueCharacters = 160;
  const maxStyleValueCharacters = 512;
  const maxSnippetCharacters = 2400;
  const maxSnippetNodes = 512;
  const maxSelectionRecoveryAttempts = 8;
  const maxAnnotationReferences = 8;
  const mutationEmissionInterval = 100;
  const redactedValue = "<redacted>";
  const sensitiveNamePattern = /(?:^|[-_:])(api[-_]?key|auth|authorization|credential|csrf|password|passwd|secret|session|token)(?:$|[-_:])/i;
  const sensitiveAutocompletePattern = /(?:current-password|new-password|one-time-code|cc-number|cc-csc)/i;
  const voidElements = new Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]);

  let enabled = false;
  let revision = 0;
  let selectedElement = null;
  let selectedBaseline = null;
  let selectedIdentity = null;
  let activeReference = null;
  let hoveredElement = null;
  let hoveredSelectionIndex = null;
  let overlayHost = null;
  let overlay = null;
  let observer = null;
  let refreshScheduled = false;
  let selectionIdentityNeedsRefresh = false;
  let selectionRecoveryFrame = 0;
  let selectionRecoveryAttemptsRemaining = 0;
  let editStateNeedsEmit = false;
  let overlayFrame = 0;
  let captureHidden = false;
  let captureSelectionValid = true;
  let mutationEmissionFrame = 0;
  let lastMutationEmissionAt = 0;
  let lastMutationEmissionSignature = "";
  const edits = new Map();
  const styleOriginals = new Map();
  const textOriginals = new Map();
  const selectedReferences = [];
  // Each selection gets a stable palette color by position, shared between
  // its page outline and its composer pill so users can match them.
  const selectionPalette = [
    "#0A84FF", "#AF52DE", "#FF9F0A", "#30D158",
    "#FF375F", "#64D2FF", "#FFD60A", "#5E5CE6",
    "#66D4CF", "#FF7F50", "#DA8FFF", "#B0D63F",
    "#FF5AC8", "#A2845E",
  ];
  const selectionColor = (index) => selectionPalette[((index % selectionPalette.length) + selectionPalette.length) % selectionPalette.length];
  // Colors stick to a selection for its lifetime (assigned at pick time);
  // removals must not recolor the surviving pills/outlines.
  let colorSequence = 0;
  // The color the NEXT pick will take; hover/marquee targeting previews it so
  // the target is already tinted like the pill and outline it will become.
  const upcomingColor = () => selectionColor(colorSequence);
  const colorChannels = (hex) => [
    parseInt(hex.slice(1, 3), 16),
    parseInt(hex.slice(3, 5), 16),
    parseInt(hex.slice(5, 7), 16),
  ];
  const colorWithAlpha = (hex, alpha) => {
    const [r, g, b] = colorChannels(hex);
    return `rgba(${r}, ${g}, ${b}, ${alpha})`;
  };
  // Legible badge text on both dark (blue/purple) and bright (yellow) tints.
  const contrastingTextColor = (hex) => {
    const [r, g, b] = colorChannels(hex);
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.62 ? "rgba(0, 0, 0, 0.88)" : "white";
  };

  // Captured annotation regions: one immutable context artifact per stroke.
  const regionReferences = [];
  const marqueeThresholdPixels = 5;
  let pendingPointer = null;
  let marqueeActive = false;
  let marqueePoints = [];
  let annotationSequence = 0;
  let pendingAnnotation = null;
  let annotationPhase = "idle";
  let suppressClicksUntil = 0;
  // Exclusive interaction modes: "select" picks elements, "draw" captures
  // freehand regions. Never both at once.
  let interactionMode = "select";

  // Comments (cmux-next; David Beyer 2026-11-20: "I like the way Codex does it ... if I wanna do a
  // lot of them, this would be visually messy"). A click opens one small comment bubble under the
  // element, with no buttons: Return adds the pick with its comment, Shift-Return is a new line,
  // Escape drops it. An added pick keeps a numbered pin; clicking it again edits its comment, and
  // Delete on an emptied comment removes it. Only added picks are in snapshots, so the chat gets
  // one card per pick, once, with its comment.
  const maxCommentCharacters = 2000;
  // The bubble's words, in the app's language (`configure`); English until then.
  let strings = {
    placeholder: "Add a comment", add: "Return to add", save: "Return to save",
    send: "Command-Return to send to agent", sending: "Sending…", sent: "Sent", answered: "Agent replied",
    failed: "Not answered", resolve: "Resolve",
  };
  // Comment threads (diff-comments-threads-v1): when the workspace's agent chat keeps them, Command-Return
  // in a bubble adds the pick and asks the app to send it to the agent at once
  // (`send_requested`), and the pick's thread card next to its pin shows "Sent", then the agent's
  // reply, with Resolve (`thread_resolve`). Both are posted only for a real key or click. Off, the
  // pick goes to the chat composer as a chip, as before.
  let sendAvailable = false;
  const maxReplyCharacters = 8000;
  // The pick whose bubble is open: `{ reference, isNew }`, or null.
  let draft = null;
  // The native composer card's viewport rect. The webview's tracking area
  // still receives mouse moves over the card (tracking ignores z-order), so
  // the runtime must treat that region as hover-dead itself.
  let composerFrame = null;

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

  // Absolute XPath (id-anchored when possible), the primary human-facing
  // element identity in badges, chips, and the copied payload.
  //
  // An id anchors the path only when it is plainly literal-safe (no quotes or
  // exotic characters), non-sensitive, and unique in the document; anything
  // else falls back to the positional path so badges and payloads never carry
  // user-bearing or ambiguous identifiers.
  const xpathAnchorId = (node) => {
    const id = node.id;
    if (!id || id.length > 64) return null;
    if (!/^[A-Za-z0-9._:-]+$/.test(id)) return null;
    if (hasSensitiveName(id)) return null;
    try {
      if (document.querySelectorAll(`[id="${cssEscape(id)}"]`).length !== 1) return null;
    } catch (_) {
      return null;
    }
    return id;
  };

  const xpathFor = (element) => {
    const parts = [];
    let current = element;
    while (current && current.nodeType === 1) {
      const anchor = xpathAnchorId(current);
      if (anchor) {
        parts.unshift(`//*[@id="${anchor}"]`);
        return parts.join("/");
      }
      let index = 1;
      let sibling = current.previousElementSibling;
      while (sibling) {
        if (sibling.localName === current.localName) index += 1;
        sibling = sibling.previousElementSibling;
      }
      parts.unshift(`${current.localName || "*"}[${index}]`);
      current = current.parentElement;
    }
    return `/${parts.join("/")}`;
  };

  const truncateMiddle = (value, max = 64) => (
    value.length <= max
      ? value
      : `${value.slice(0, Math.ceil(max / 2) - 1)}…${value.slice(-Math.floor(max / 2))}`
  );

  // Guaranteed-unique fallback: an nth-child path from the nearest #id
  // ancestor (or the root) down to the element. Unlike structuralSelector's
  // bounded walk, this always resolves to exactly one element, so deeply
  // nested elements with repeated class patterns stay selectable.
  const pathSelector = (element) => {
    const parts = [];
    let current = element;
    while (current && current.nodeType === 1) {
      if (current.id && current.id.length <= maxSelectorValueCharacters) {
        parts.unshift(`#${cssEscape(current.id)}`);
        break;
      }
      const parent = current.parentElement;
      if (!parent) {
        parts.unshift(current.localName || "*");
        break;
      }
      const index = Array.prototype.indexOf.call(parent.children, current) + 1;
      parts.unshift(`${current.localName || "*"}:nth-child(${index})`);
      current = parent;
    }
    return parts.join(" > ");
  };

  const selectorsFor = (element) => {
    // Redaction boundary: every form control is classified sensitive, and
    // selection recovery depends on unique selectors, so developer-assigned
    // identifiers (id, name, data-testid) stay usable as selector sources.
    // User-bearing content (values, text, accessibility labels) is redacted.
    const candidates = [];
    if (element.id && element.id.length <= maxSelectorValueCharacters) {
      candidates.push(`#${cssEscape(element.id)}`);
    }
    const sensitive = isSensitiveElement(element);
    for (const name of preferredAttributes) {
      // Accessibility labels on sensitive controls can embed user
      // identifiers; never derive selectors from them.
      if (sensitive && name === "aria-label") continue;
      const value = element.getAttribute?.(name);
      if (!value || value.length > 160) continue;
      candidates.push(`${element.localName}[${name}="${attributeValue(value)}"]`);
      candidates.push(`[${name}="${attributeValue(value)}"]`);
    }
    const classes = classSelector(element);
    if (classes) candidates.push(classes);
    candidates.push(structuralSelector(element));
    candidates.push(pathSelector(element));

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
    if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement
        || ["select", "option", "optgroup"].includes(element.localName)) return true;
    let editableAncestor = element;
    while (editableAncestor) {
      const contentEditable = String(editableAncestor.getAttribute?.("contenteditable") || "").toLowerCase();
      const role = String(editableAncestor.getAttribute?.("role") || "").toLowerCase();
      if (editableAncestor.isContentEditable
          || (editableAncestor.hasAttribute?.("contenteditable") && contentEditable !== "false")
          || ["textbox", "combobox", "listbox"].includes(role)) return true;
      editableAncestor = editableAncestor.parentElement;
    }
    const autocomplete = String(element.getAttribute?.("autocomplete") || "");
    if (sensitiveAutocompletePattern.test(autocomplete)) return true;
    return hasSensitiveName(element.getAttribute?.("name")) || hasSensitiveName(element.id);
  };

  const sanitizedAttributeValue = (element, attribute) => {
    const name = String(attribute.name || "");
    const value = String(attribute.value || "");
    if (urlBearingAttributes.has(name.toLowerCase())
        || hasSensitiveName(name)
        || (isSensitiveElement(element)
          && !["id", "name", "type", "autocomplete", "class", "role"].includes(name.toLowerCase()))
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
    const stableAttributes = [];
    let visitedAttributes = 0;
    for (const attribute of element.attributes || []) {
      visitedAttributes += 1;
      if (visitedAttributes > 64) break;
      const name = String(attribute.name || "").toLowerCase();
      if (["class", "style"].includes(name) || urlBearingAttributes.has(name) || hasSensitiveName(name)) continue;
      stableAttributes.push(`${bounded(name, maxSelectorValueCharacters)}=${bounded(attribute.value, maxSelectorValueCharacters)}`);
      if (stableAttributes.length === 16) break;
    }
    stableAttributes.sort();
    const parent = element.parentElement;
    return [
      element.namespaceURI || "",
      element.localName || "",
      bounded(element.getAttribute?.("role"), maxSelectorValueCharacters),
      bounded(element.getAttribute?.("type"), maxSelectorValueCharacters),
      JSON.stringify(stableAttributes),
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
    let visited = 0;
    let traversalExhausted = false;
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
      if (remaining <= 0 || traversalExhausted) return;
      if (visited >= maxSnippetNodes) {
        traversalExhausted = true;
        append("…");
        return;
      }
      visited += 1;
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
        for (const child of node.childNodes || []) {
          visit(child, depth + 1);
          if (traversalExhausted) break;
        }
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

  // Shipped React 19 bundles do not retain the old Fiber source hint. cmux
  // webviews can opt in at component boundaries with bounded metadata instead;
  // arbitrary pages still get the dev-only Fiber hint below when present.
  const explicitMetadataFor = (element) => {
    let node = element;
    let hops = 0;
    while (node && hops < 8) {
      const source = node.getAttribute?.("data-cmux-source");
      const component = node.getAttribute?.("data-cmux-component");
      if (source || component) {
        const match = typeof source === "string" && source.match(/^(.*):(\d+)(?::(\d+))?$/);
        return {
          component: typeof component === "string" && component.length > 0 ? component : null,
          sourceLocation: match
            ? { file: bounded(match[1], 512), line: Number(match[2]), column: match[3] ? Number(match[3]) : null }
            : null,
        };
      }
      node = node.parentElement;
      hops += 1;
    }
    return null;
  };

  // React component identity from the fiber tree (Cursor-style): nearest
  // named components up the owner chain plus the nearest component's prop
  // KEYS. Prop values are never captured — they can carry user data.
  const reactContextFor = (element) => {
    try {
      let node = element;
      let hops = 0;
      while (node && hops < 8) {
        const fiberKey = Object.keys(node).find((key) => key.startsWith("__reactFiber$"));
        if (fiberKey) {
          const components = [];
          let propKeys = null;
          let sourceLocation = null;
          let fiber = node[fiberKey];
          let steps = 0;
          while (fiber && components.length < 4 && steps < 64) {
            const type = fiber.type;
            const name = typeof type === "function"
              ? (type.displayName || type.name)
              : (type && typeof type === "object" ? (type.displayName || type.render?.displayName || type.render?.name) : null);
            if (name && name.length > 1) {
              components.push(name);
              if (!propKeys && fiber.memoizedProps && typeof fiber.memoizedProps === "object") {
                propKeys = Object.keys(fiber.memoizedProps).filter((key) => key !== "children").slice(0, 12);
              }
            }
            // React dev builds retain this source hint. Production builds do
            // not, so absence is represented by omission rather than a guess.
            if (!sourceLocation && fiber._debugSource && typeof fiber._debugSource === "object") {
              const source = fiber._debugSource;
              if (typeof source.fileName === "string" && Number.isFinite(source.lineNumber)) {
                sourceLocation = {
                  file: source.fileName,
                  line: Number(source.lineNumber),
                  column: Number.isFinite(source.columnNumber) ? Number(source.columnNumber) : null,
                };
              }
            }
            fiber = fiber.return;
            steps += 1;
          }
          if (components.length || sourceLocation) return { components, propKeys: propKeys || [], sourceLocation };
          return null;
        }
        node = node.parentElement;
        hops += 1;
      }
    } catch (_) {}
    return null;
  };

  const baselineFor = (element) => {
    const selectors = selectorsFor(element);
    if (!selectors.length) return null;
    const react = reactContextFor(element);
    const explicit = explicitMetadataFor(element);
    const components = react?.components || [];
    if (explicit?.component && !components.includes(explicit.component)) components.unshift(explicit.component);
    return {
      selector: selectors[0],
      selectors,
      xpath: xpathFor(element),
      tag_name: element.localName || "element",
      dom_snippet: boundedSnippet(element),
      text_content: boundedTextValue(element),
      text_editable: textIsEditable(element),
      computed_styles: computedStylesFor(element),
      react_components: components,
      react_prop_keys: react?.propKeys || [],
      source_location: explicit?.sourceLocation || react?.sourceLocation || null,
    };
  };

  const rebaseEdits = (baseline) => {
    for (const [id, edit] of edits) {
      if (edit.kind === "style") {
        edits.set(id, {
          ...edit,
          original_value: baseline.computed_styles?.[edit.property] || "",
        });
      } else if (edit.kind === "text" && baseline.text_editable) {
        edits.set(id, { ...edit, original_value: baseline.text_content });
      } else if (edit.kind === "text") {
        edits.delete(id);
        editStateNeedsEmit = true;
      }
    }
  };

  const setActiveReference = (reference) => {
    activeReference = reference || null;
    selectedElement = activeReference?.element || null;
    selectedBaseline = activeReference?.baseline || null;
    selectedIdentity = activeReference?.identity || null;
  };

  const updateActiveReference = () => {
    if (!activeReference) return;
    activeReference.element = selectedElement;
    activeReference.baseline = selectedBaseline;
    activeReference.identity = selectedIdentity;
  };

  const refreshSelectionForCapture = (element) => {
    const selectors = selectorsFor(element);
    captureSelectionValid = selectors.length > 0;
    if (!captureSelectionValid) return false;
    const identityChanged = selectors[0] !== selectedBaseline.selector
      || selectors.length !== selectedBaseline.selectors.length
      || selectors.some((selector, index) => selector !== selectedBaseline.selectors[index]);
    selectedBaseline = { ...selectedBaseline, selector: selectors[0], selectors };
    selectedIdentity = identityFor(element);
    updateActiveReference();
    if (identityChanged) revision += 1;
    return true;
  };

  const referenceElement = (reference, allowRecovery = false) => {
    if (!reference) return null;
    if (reference === activeReference) return resolveSelectedElement(allowRecovery);
    if (reference.element?.isConnected) return reference.element;
    if (!allowRecovery) return null;
    for (const selector of reference.baseline?.selectors || []) {
      try {
        const candidates = document.querySelectorAll(selector);
        if (candidates.length !== 1 || identityFor(candidates[0]) !== reference.identity) continue;
        const recoveredBaseline = baselineFor(candidates[0]);
        if (!recoveredBaseline) continue;
        reference.element = candidates[0];
        reference.baseline = recoveredBaseline;
        reference.identity = identityFor(candidates[0]);
        return candidates[0];
      } catch (_) {}
    }
    reference.element = null;
    return null;
  };

  const selectionSnapshotFor = (reference) => {
    const element = referenceElement(reference, captureHidden);
    if (!element || !reference?.baseline) return null;
    if (captureHidden && reference === activeReference && !refreshSelectionForCapture(element)) return null;
    if (captureHidden && reference !== activeReference) {
      const selectors = selectorsFor(element);
      if (!selectors.length) return null;
      reference.baseline = { ...reference.baseline, selector: selectors[0], selectors };
      reference.identity = identityFor(element);
    }
    return {
      ...reference.baseline,
      bounds: rectFor(element),
      viewport: {
        width: globalThis.innerWidth || 0,
        height: globalThis.innerHeight || 0,
        scroll_x: globalThis.scrollX || 0,
        scroll_y: globalThis.scrollY || 0,
      },
    };
  };

  // Annotation snapshots translate page-anchored regions to current viewport
  // coordinates while keeping a stable identity across scrolling.
  const regionSnapshotFor = (region) => {
    const x = region.pageX - (globalThis.scrollX || 0);
    const y = region.pageY - (globalThis.scrollY || 0);
    return {
      selector: `@annotation(${region.id})`,
      selectors: [],
      xpath: "",
      tag_name: "region",
      dom_snippet: "",
      text_content: "",
      text_editable: false,
      bounds: { x, y, width: region.width, height: region.height },
      viewport: {
        width: globalThis.innerWidth || 0,
        height: globalThis.innerHeight || 0,
        scroll_x: globalThis.scrollX || 0,
        scroll_y: globalThis.scrollY || 0,
      },
      computed_styles: {},
    };
  };

  // A pick is in snapshots once added (Return in its bubble), numbered as its pin is.
  const addedReferences = () => selectedReferences.filter((reference) => reference.added !== false);

  // The number a pick's pin shows: its place among added picks, or the next one for a new pick
  // whose bubble is still open.
  const pickNumber = (reference) => {
    const index = addedReferences().indexOf(reference);
    return index >= 0 ? index + 1 : addedReferences().length + 1;
  };

  const selectionSnapshots = () => {
    const elementItems = addedReferences()
      .map((reference, index) => {
        const item = selectionSnapshotFor(reference);
        if (!item) return null;
        item.color = selectionColor(reference.colorIndex || 0);
        item.number = index + 1;
        item.comment = reference.comment || "";
        return item;
      })
      .filter(Boolean);
    const regionItems = regionReferences.map((region, index) => {
      const item = regionSnapshotFor(region);
      item.color = selectionColor(region.colorIndex || 0);
      item.number = elementItems.length + index + 1;
      item.comment = "";
      return item;
    });
    return elementItems.concat(regionItems);
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
    const selections = selectionSnapshots();
    const selection = selections[selections.length - 1] || null;
    const value = {
      revision,
      enabled,
      selection,
      selections,
      edits: Array.from(edits.values()),
      css_diff: cssDiff(),
    };
    try {
      if (JSON.stringify(value).length <= maxSnapshotCharacters) return value;
    } catch (_) {}
    return { revision, enabled, selection: null, selections: [], edits: [], css_diff: "" };
  };

  const presentationSignature = (value) => JSON.stringify([
    value.enabled, value.selections, value.edits, value.css_diff,
  ]);

  const postSnapshot = (value) => {
    try {
      handler?.postMessage({ type: "snapshot", snapshot: value });
    } catch (_) {}
    return value;
  };

  const emit = () => {
    const value = snapshot();
    lastMutationEmissionSignature = presentationSignature(value);
    return postSnapshot(value);
  };

  const flushMutationEmission = (timestamp) => {
    if (!enabled) {
      mutationEmissionFrame = 0;
      return;
    }
    if (timestamp - lastMutationEmissionAt < mutationEmissionInterval) {
      mutationEmissionFrame = requestAnimationFrame(flushMutationEmission);
      return;
    }
    mutationEmissionFrame = 0;
    lastMutationEmissionAt = timestamp;
    const value = snapshot();
    const signature = presentationSignature(value);
    if (signature === lastMutationEmissionSignature) return;
    lastMutationEmissionSignature = signature;
    postSnapshot(value);
  };

  const scheduleMutationEmission = () => {
    if (!mutationEmissionFrame) mutationEmissionFrame = requestAnimationFrame(flushMutationEmission);
  };

  const cancelMutationEmission = () => {
    if (mutationEmissionFrame) cancelAnimationFrame(mutationEmissionFrame);
    mutationEmissionFrame = 0;
  };

  const resolveSelectedElement = (allowRecovery = false) => {
    if (!selectedBaseline) return null;
    if (selectedElement?.isConnected) return selectedElement;
    if (!allowRecovery) return null;
    for (const selector of selectedBaseline.selectors) {
      try {
        const candidates = document.querySelectorAll(selector);
        if (candidates.length === 1 && identityFor(candidates[0]) === selectedIdentity) {
          const recoveredBaseline = baselineFor(candidates[0]);
          if (!recoveredBaseline) continue;
          selectedElement = candidates[0];
          selectedBaseline = recoveredBaseline;
          selectedIdentity = identityFor(candidates[0]);
          rebaseEdits(recoveredBaseline);
          updateActiveReference();
          return candidates[0];
        }
      } catch (_) {}
    }
    selectedElement = null;
    updateActiveReference();
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

  const capturePageStyleMutation = (element) => {
    const originals = styleOriginals.get(element);
    if (!originals) return;
    for (const edit of edits.values()) {
      if (edit.kind !== "style" || !originals.has(edit.property)) continue;
      const value = element.style.getPropertyValue(edit.property);
      const priority = element.style.getPropertyPriority(edit.property);
      if (value !== edit.value || priority !== "important") {
        originals.set(edit.property, { value, priority });
      }
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

  const directTextNodes = (element) => {
    const result = [];
    for (const node of element.childNodes || []) {
      if (node.nodeType === 3) result.push(node);
    }
    return result;
  };

  const rememberTextOriginal = (element) => {
    if (textOriginals.has(element)) return true;
    if (!textIsEditable(element)) return false;
    const originals = new Map();
    for (const node of directTextNodes(element)) originals.set(node, node.nodeValue || "");
    textOriginals.set(element, {
      originals,
      injected: new Set(),
      target: originals.keys().next().value || null,
    });
    return true;
  };

  const restoreTextState = (element, state) => {
    for (const [node, value] of state.originals) {
      if (node.parentNode === element && node.nodeValue !== value) node.nodeValue = value;
    }
    for (const node of state.injected) {
      if (node.parentNode === element) node.remove();
    }
  };

  const restoreText = () => {
    for (const [element, state] of textOriginals) restoreTextState(element, state);
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
    const textState = textOriginals.get(element);
    if (!textState) return;
    restoreTextState(element, textState);
    textOriginals.delete(element);
  };

  const applyText = (element, value) => {
    if (!textIsEditable(element)) {
      capturePageTextMutation(element);
      return false;
    }
    if (!rememberTextOriginal(element)) return false;
    const state = textOriginals.get(element);
    const nodes = directTextNodes(element);
    for (const node of nodes) {
      if (!state.originals.has(node) && !state.injected.has(node)) {
        state.originals.set(node, node.nodeValue || "");
      }
    }
    if (state.target?.parentNode !== element) state.target = nodes[0] || null;
    if (!state.target) {
      state.target = document.createTextNode("");
      state.injected.add(state.target);
      element.appendChild(state.target);
      nodes.push(state.target);
    }
    for (const node of nodes) {
      const nextValue = node === state.target ? value : "";
      if (node.nodeValue !== nextValue) node.nodeValue = nextValue;
    }
    return true;
  };

  const capturePageTextMutation = (element) => {
    const edit = edits.get("text:text-content");
    if (!edit || edit.kind !== "text") return false;
    const state = textOriginals.get(element);
    if (!state) return false;
    const expectedValue = (node) => node === state.target ? edit.value : "";
    for (const [node] of state.originals) {
      if (node.parentNode !== element) {
        state.originals.delete(node);
      } else if (node.nodeValue !== expectedValue(node)) {
        state.originals.set(node, node.nodeValue || "");
      }
    }
    for (const node of state.injected) {
      if (node.parentNode !== element) {
        state.injected.delete(node);
      } else if (node.nodeValue !== expectedValue(node)) {
        state.injected.delete(node);
        state.originals.set(node, node.nodeValue || "");
      }
    }
    if (!textIsEditable(element)) {
      edits.delete(edit.id);
      restoreTextState(element, state);
      textOriginals.delete(element);
      return true;
    }
    const nodes = directTextNodes(element);
    for (const node of nodes) {
      if (!state.originals.has(node) && !state.injected.has(node)) {
        state.originals.set(node, node.nodeValue || "");
      }
    }
    if (state.target?.parentNode !== element) state.target = nodes[0] || null;
    return false;
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

  const annotationPolyline = () => {
    const path = document.createElementNS("http://www.w3.org/2000/svg", "polyline");
    path.setAttribute("fill", "none");
    path.setAttribute("stroke-width", "2.5");
    path.setAttribute("stroke-linecap", "round");
    path.setAttribute("stroke-linejoin", "round");
    return path;
  };

  const createOverlay = () => {
    if (overlayHost?.isConnected) return;
    overlayHost = document.createElement("div");
    overlayHost.setAttribute("data-cmux-design-mode", "overlay");
    overlayHost.style.setProperty("all", "initial", "important");
    overlayHost.style.setProperty("position", "fixed", "important");
    overlayHost.style.setProperty("inset", "0", "important");
    overlayHost.style.setProperty("pointer-events", "auto", "important");
    overlayHost.style.setProperty("z-index", "2147483647", "important");
    const shadow = overlayHost.attachShadow({ mode: "closed" });

    const shield = document.createElement("div");
    Object.assign(shield.style, {
      display: "block",
      position: "fixed",
      inset: "0",
      pointerEvents: "auto",
      cursor: "crosshair",
      background: "transparent",
    });

    const margin = box("margin", "transparent");
    const border = box("border", "transparent");
    const padding = box("padding", "transparent");
    const content = box("content", "rgba(10, 132, 255, 0.13)");
    content.style.outline = "1.5px solid rgb(10, 132, 255)";
    content.style.outlineOffset = "-1px";

    const selectionLayer = document.createElement("div");
    Object.assign(selectionLayer.style, {
      position: "fixed",
      inset: "0",
      pointerEvents: "none",
    });

    const badge = document.createElement("div");
    Object.assign(badge.style, {
      display: "none",
      position: "fixed",
      pointerEvents: "none",
      maxWidth: "min(520px, calc(100vw - 16px))",
      padding: "5px 10px",
      borderRadius: "6px",
      color: "white",
      background: "rgb(10, 132, 255)",
      boxShadow: "0 2px 8px rgba(0, 0, 0, 0.35)",
      font: "600 12px/1.3 -apple-system, BlinkMacSystemFont, sans-serif",
      whiteSpace: "nowrap",
      overflow: "hidden",
      textOverflow: "ellipsis",
    });

    const marqueeBox = document.createElement("div");
    Object.assign(marqueeBox.style, {
      display: "none",
      position: "fixed",
      pointerEvents: "none",
      boxSizing: "border-box",
      border: "1.5px dashed rgba(10, 132, 255, 0.85)",
      borderRadius: "3px",
      background: "rgba(10, 132, 255, 0.07)",
    });

    const svgNS = "http://www.w3.org/2000/svg";
    const regionInkSvg = document.createElementNS(svgNS, "svg");
    Object.assign(regionInkSvg.style, {
      display: "none",
      position: "fixed",
      inset: "0",
      width: "100vw",
      height: "100vh",
      pointerEvents: "none",
    });

    // The active stroke is isolated while native captures its context. After
    // completion, the same page-anchored points move into `regionInkSvg`.
    const strokeSvg = document.createElementNS(svgNS, "svg");
    Object.assign(strokeSvg.style, {
      display: "none",
      position: "fixed",
      inset: "0",
      width: "100vw",
      height: "100vh",
      pointerEvents: "none",
    });
    const strokePath = annotationPolyline();
    strokePath.setAttribute("stroke", "rgb(229, 83, 75)");
    strokeSvg.append(strokePath);

    // The pins and the comment bubble: styled in the closed root, so the page's CSS never reaches them.
    const style = document.createElement("style");
    style.textContent = bubbleStyles;
    const pinLayer = document.createElement("div");
    Object.assign(pinLayer.style, { position: "fixed", inset: "0", pointerEvents: "none" });
    const bubble = document.createElement("div");
    bubble.className = "bubble";
    bubble.setAttribute("data-cmux-bubble", "");
    bubble.setAttribute("role", "dialog");
    const bubbleHead = document.createElement("div");
    bubbleHead.className = "head";
    const bubbleNumber = document.createElement("span");
    bubbleNumber.className = "num";
    const bubbleWhat = document.createElement("span");
    bubbleWhat.className = "what";
    bubbleHead.append(bubbleNumber, bubbleWhat);
    const field = document.createElement("textarea");
    field.rows = 1;
    field.spellcheck = true;
    field.setAttribute("aria-label", strings.placeholder);
    const bubbleHint = document.createElement("div");
    bubbleHint.className = "hint";
    bubbleHint.setAttribute("aria-hidden", "true");
    bubble.append(bubbleHead, field, bubbleHint);
    const threadLayer = document.createElement("div");
    Object.assign(threadLayer.style, { position: "fixed", inset: "0", pointerEvents: "none" });

    shadow.append(
      style,
      shield,
      regionInkSvg,
      selectionLayer,
      marqueeBox,
      strokeSvg,
      margin,
      border,
      padding,
      content,
      badge,
      pinLayer,
      threadLayer,
      bubble,
    );
    document.documentElement.appendChild(overlayHost);
    overlay = {
      shadow, shield, selectionLayer, selectionOutlines: [], regionOutlines: [], marqueeBox,
      regionInkSvg, regionInkPaths: [], strokeSvg, strokePath,
      margin, border, padding, content, badge,
      pinLayer, pins: [], threadLayer, threadCards: [], bubble, bubbleNumber, bubbleWhat, field, bubbleHint,
    };
  };

  // The bubble and pins (emil-design-foundations / emil-animations): a system-font card with a
  // hairline edge and a soft two-layer shadow, light and dark; it enters in 160 ms with a strong
  // ease-out from 4 px above and 0.98 scale, and only fades when motion is reduced. Pins are the
  // pick's own color with a white ring, so they read on any page.
  const bubbleStyles = `
    .bubble { position: fixed; display: none; box-sizing: border-box; width: 296px; max-width: calc(100vw - 16px);
      padding: 9px 12px 8px; border-radius: 12px; background: rgba(255, 255, 255, 0.98); color: rgba(0, 0, 0, 0.88);
      border: 0.5px solid rgba(0, 0, 0, 0.14); box-shadow: 0 12px 32px rgba(0, 0, 0, 0.16), 0 2px 6px rgba(0, 0, 0, 0.08);
      font: 13px/18px -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; -webkit-font-smoothing: antialiased;
      pointer-events: auto; cursor: auto; text-align: left; transform-origin: var(--origin, top left); }
    .bubble[data-open] { display: block; animation: cmux-bubble-in 160ms cubic-bezier(0.23, 1, 0.32, 1); }
    @keyframes cmux-bubble-in { from { opacity: 0; transform: translateY(var(--from, -4px)) scale(0.98); } to { opacity: 1; transform: none; } }
    @keyframes cmux-bubble-fade { from { opacity: 0; } to { opacity: 1; } }
    .head { display: flex; align-items: center; gap: 6px; min-width: 0; margin-bottom: 3px; font-size: 11px; line-height: 16px;
      color: rgba(0, 0, 0, 0.5); }
    .num { flex: none; min-width: 16px; height: 16px; padding: 0 4px; box-sizing: border-box; border-radius: 8px;
      font-weight: 600; font-size: 10px; line-height: 16px; text-align: center; font-variant-numeric: tabular-nums; }
    .what { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    textarea { display: block; box-sizing: border-box; width: 100%; height: 22px; max-height: 128px; margin: 0; padding: 2px 0;
      border: 0; outline: none; resize: none; overflow-y: auto; background: transparent; color: inherit; font: inherit; }
    textarea::placeholder { color: rgba(0, 0, 0, 0.36); }
    .hint { margin-top: 2px; text-align: right; font-size: 11px; line-height: 14px; color: rgba(0, 0, 0, 0.38); }
    .pin { position: fixed; display: none; box-sizing: border-box; min-width: 20px; height: 20px; padding: 0 5px;
      border-radius: 10px; border: 2px solid #fff; box-shadow: 0 1px 4px rgba(0, 0, 0, 0.32);
      font: 600 11px/16px -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; text-align: center;
      font-variant-numeric: tabular-nums; -webkit-font-smoothing: antialiased; pointer-events: none;
      animation: cmux-pin-in 160ms cubic-bezier(0.23, 1, 0.32, 1); }
    .pin[data-draft] { opacity: 0.85; }
    .thread { position: fixed; display: none; box-sizing: border-box; width: 264px; max-width: calc(100vw - 16px);
      max-height: 220px; overflow-y: auto; padding: 7px 10px 8px; border-radius: 10px; background: rgba(255, 255, 255, 0.98);
      color: rgba(0, 0, 0, 0.88); border: 0.5px solid rgba(0, 0, 0, 0.14);
      box-shadow: 0 8px 24px rgba(0, 0, 0, 0.14), 0 1px 4px rgba(0, 0, 0, 0.08);
      font: 12px/17px -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; -webkit-font-smoothing: antialiased;
      pointer-events: auto; cursor: auto; text-align: left; animation: cmux-bubble-fade 120ms ease-out; }
    .thread .state { display: flex; align-items: center; gap: 6px; font-size: 11px; line-height: 16px; font-weight: 600;
      color: rgba(0, 0, 0, 0.5); }
    .thread[data-state="sending"] .state::before, .thread[data-state="sent"] .state::before { content: ""; width: 6px; height: 6px;
      border-radius: 3px; background: rgb(10, 132, 255); animation: cmux-thread-pulse 1.2s ease-in-out infinite; }
    @keyframes cmux-thread-pulse { 0%, 100% { opacity: 0.35; } 50% { opacity: 1; } }
    .thread .reply { margin-top: 3px; white-space: pre-wrap; overflow-wrap: anywhere; }
    .thread .reply:empty { display: none; }
    .thread .resolve { display: none; margin-top: 6px; padding: 2px 8px; border: 0.5px solid rgba(0, 0, 0, 0.2); border-radius: 6px;
      background: transparent; color: inherit; font: inherit; font-size: 11px; cursor: pointer; }
    .thread[data-state="sent"] .resolve, .thread[data-state="answered"] .resolve, .thread[data-state="failed"] .resolve { display: inline-block; }
    @keyframes cmux-pin-in { from { opacity: 0; transform: scale(0.6); } to { opacity: 1; transform: none; } }
    @media (prefers-color-scheme: dark) {
      .bubble { background: rgba(40, 40, 43, 0.98); color: rgba(255, 255, 255, 0.92); border-color: rgba(255, 255, 255, 0.16);
        box-shadow: 0 12px 32px rgba(0, 0, 0, 0.5), 0 2px 6px rgba(0, 0, 0, 0.3); }
      .head { color: rgba(255, 255, 255, 0.55); }
      textarea::placeholder { color: rgba(255, 255, 255, 0.36); }
      .hint { color: rgba(255, 255, 255, 0.4); }
      .thread { background: rgba(40, 40, 43, 0.98); color: rgba(255, 255, 255, 0.92); border-color: rgba(255, 255, 255, 0.16); }
      .thread .state { color: rgba(255, 255, 255, 0.55); }
      .thread .resolve { border-color: rgba(255, 255, 255, 0.24); }
    }
    @media (prefers-reduced-motion: reduce) {
      .bubble[data-open] { animation: cmux-bubble-fade 120ms ease-out; }
      .pin { animation: none; }
      .thread, .thread .state::before { animation: none; }
    }
  `;

  const hideOverlay = () => {
    if (!overlay) return;
    for (const name of [
      "margin", "border", "padding", "content", "badge", "marqueeBox",
      "regionInkSvg", "strokeSvg",
    ]) {
      overlay[name].style.display = "none";
    }
    for (const outline of overlay.selectionOutlines) outline.style.display = "none";
    for (const outline of overlay.regionOutlines) outline.style.display = "none";
    for (const pin of overlay.pins) pin.style.display = "none";
    for (const card of overlay.threadCards) card.style.display = "none";
    overlay.bubble.style.display = "none";
    overlay.shield.style.display = enabled && !captureHidden ? "block" : "none";
  };

  const place = (element, rect) => {
    element.style.display = "block";
    element.style.left = `${rect.x}px`;
    element.style.top = `${rect.y}px`;
    element.style.width = `${Math.max(0, rect.width)}px`;
    element.style.height = `${Math.max(0, rect.height)}px`;
  };

  const selectedOutline = () => {
    const element = document.createElement("div");
    Object.assign(element.style, {
      display: "none",
      position: "fixed",
      pointerEvents: "none",
      boxSizing: "border-box",
      border: "1.5px solid rgb(10, 132, 255)",
      borderRadius: "2px",
      background: "transparent",
    });
    return element;
  };

  const annotationOutline = () => {
    const element = document.createElement("div");
    Object.assign(element.style, {
      display: "none",
      position: "fixed",
      pointerEvents: "none",
      boxSizing: "border-box",
      border: "1.5px dashed rgb(10, 132, 255)",
      borderRadius: "14px",
      backgroundColor: "transparent",
      boxShadow: "none",
    });
    return element;
  };

  const refreshSelectedOutlines = () => {
    if (!overlay) return;
    while (overlay.selectionOutlines.length < selectedReferences.length) {
      const outline = selectedOutline();
      overlay.selectionOutlines.push(outline);
      overlay.selectionLayer.append(outline);
    }
    for (let index = 0; index < overlay.selectionOutlines.length; index += 1) {
      const outline = overlay.selectionOutlines[index];
      const reference = selectedReferences[index];
      const element = referenceElement(reference, false);
      if (!element || !reference) {
        outline.style.display = "none";
        continue;
      }
      // The selection's lifetime color, matching its composer pill.
      const tint = selectionColor(reference.colorIndex || 0);
      outline.style.borderColor = tint;
      const isHovered = hoveredSelectionIndex === index;
      outline.style.background = isHovered ? colorWithAlpha(tint, 0.13) : "transparent";
      outline.style.boxShadow = isHovered ? `0 0 0 4px ${colorWithAlpha(tint, 0.55)}` : "none";
      place(outline, element.getBoundingClientRect());
    }
    refreshRegionOutlines();
    refreshPins();
    positionBubble();
  };

  // One numbered pin on each pick's top-left corner, kept inside the viewport.
  const refreshPins = () => {
    if (!overlay) return;
    while (overlay.pins.length < selectedReferences.length) {
      const pin = document.createElement("div");
      pin.className = "pin";
      pin.setAttribute("data-cmux-pin", "");
      overlay.pins.push(pin);
      overlay.pinLayer.append(pin);
    }
    for (let index = 0; index < overlay.pins.length; index += 1) {
      const pin = overlay.pins[index];
      const reference = selectedReferences[index];
      const element = reference && referenceElement(reference, false);
      if (!element) {
        pin.style.display = "none";
        continue;
      }
      const tint = selectionColor(reference.colorIndex || 0);
      const rect = element.getBoundingClientRect();
      pin.textContent = String(pickNumber(reference));
      pin.style.background = tint;
      pin.style.color = contrastingTextColor(tint);
      pin.toggleAttribute("data-draft", reference.added === false);
      pin.style.display = "block";
      pin.style.left = `${Math.max(4, Math.min(rect.left - 9, (globalThis.innerWidth || 0) - 26))}px`;
      pin.style.top = `${Math.max(4, Math.min(rect.top - 9, (globalThis.innerHeight || 0) - 24))}px`;
    }
    refreshThreads();
  };

  // A pick's thread card (`setThread`): beside its pin, inside the viewport.
  const threadCard = () => {
    const card = document.createElement("div");
    card.className = "thread";
    card.setAttribute("data-cmux-thread", "");
    card.setAttribute("role", "status");
    const state = document.createElement("div");
    state.className = "state";
    const reply = document.createElement("div");
    reply.className = "reply";
    const resolve = document.createElement("button");
    resolve.className = "resolve";
    resolve.type = "button";
    resolve.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      if (!event.isTrusted || !card.cmuxSelector) return;
      try { handler?.postMessage({ type: "thread_resolve", selector: card.cmuxSelector }); } catch (_) {}
    });
    card.append(state, reply, resolve);
    card.cmuxParts = { state, reply, resolve };
    return card;
  };

  const refreshThreads = () => {
    if (!overlay) return;
    while (overlay.threadCards.length < selectedReferences.length) {
      const card = threadCard();
      overlay.threadCards.push(card);
      overlay.threadLayer.append(card);
    }
    const viewWidth = globalThis.innerWidth || 0;
    const viewHeight = globalThis.innerHeight || 0;
    for (let index = 0; index < overlay.threadCards.length; index += 1) {
      const card = overlay.threadCards[index];
      const reference = selectedReferences[index];
      const thread = reference?.thread;
      const element = thread && referenceElement(reference, false);
      if (!element) {
        card.style.display = "none";
        card.cmuxSelector = null;
        continue;
      }
      const parts = card.cmuxParts;
      card.cmuxSelector = reference.baseline?.selector || null;
      card.setAttribute("data-state", thread.state);
      parts.state.textContent = strings[thread.state] || strings.sent;
      if (parts.reply.textContent !== thread.reply) parts.reply.textContent = thread.reply;
      parts.resolve.textContent = strings.resolve;
      card.style.display = "block";
      const rect = element.getBoundingClientRect();
      const width = card.offsetWidth || 264;
      const height = card.offsetHeight || 40;
      card.style.left = `${Math.max(8, Math.min(rect.left + 16, viewWidth - width - 8))}px`;
      card.style.top = `${Math.max(8, Math.min(rect.top - 9, viewHeight - height - 8))}px`;
    }
  };

  // The open bubble under its element (above when there is no room below), inside the viewport.
  const positionBubble = () => {
    if (!overlay) return;
    const element = draft && referenceElement(draft.reference, false);
    if (!element) {
      overlay.bubble.style.display = "none";
      return;
    }
    overlay.bubble.style.display = "";
    const rect = element.getBoundingClientRect();
    const width = overlay.bubble.offsetWidth || 296;
    const height = overlay.bubble.offsetHeight || 72;
    const viewWidth = globalThis.innerWidth || 0;
    const viewHeight = globalThis.innerHeight || 0;
    const below = rect.bottom + 8;
    const fitsBelow = below + height <= viewHeight - 8;
    const top = fitsBelow ? below : Math.max(8, rect.top - 8 - height);
    const left = Math.max(8, Math.min(rect.left, viewWidth - width - 8));
    overlay.bubble.style.left = `${left}px`;
    overlay.bubble.style.top = `${Math.max(8, Math.min(top, viewHeight - height - 8))}px`;
    overlay.bubble.style.setProperty("--from", fitsBelow ? "-4px" : "4px");
    overlay.bubble.style.setProperty("--origin", fitsBelow ? "top left" : "bottom left");
  };

  const refreshRegionOutlines = () => {
    if (!overlay) return;
    while (overlay.regionOutlines.length < regionReferences.length) {
      const outline = annotationOutline();
      overlay.regionOutlines.push(outline);
      overlay.selectionLayer.append(outline);
    }
    for (let index = 0; index < overlay.regionOutlines.length; index += 1) {
      const outline = overlay.regionOutlines[index];
      const region = regionReferences[index];
      if (!region) {
        outline.style.display = "none";
        continue;
      }
      const tint = selectionColor(region.colorIndex || 0);
      const isHovered = hoveredSelectionIndex === selectedReferences.length + index;
      outline.style.borderColor = tint;
      outline.style.boxShadow = isHovered
        ? `0 0 0 4px ${colorWithAlpha(tint, 0.55)}`
        : "none";
      place(outline, {
        x: region.pageX - (globalThis.scrollX || 0),
        y: region.pageY - (globalThis.scrollY || 0),
        width: region.width,
        height: region.height,
      });
    }
    while (overlay.regionInkPaths.length < regionReferences.length) {
      const path = annotationPolyline();
      overlay.regionInkPaths.push(path);
      overlay.regionInkSvg.append(path);
    }
    const scrollX = globalThis.scrollX || 0;
    const scrollY = globalThis.scrollY || 0;
    let hasVisibleInk = false;
    for (let index = 0; index < overlay.regionInkPaths.length; index += 1) {
      const path = overlay.regionInkPaths[index];
      const region = regionReferences[index];
      if (!region || region.pagePoints.length < 2) {
        path.style.display = "none";
        path.setAttribute("points", "");
        continue;
      }
      path.setAttribute("stroke", selectionColor(region.colorIndex || 0));
      path.setAttribute(
        "points",
        region.pagePoints
          .map((point) => `${point.x - scrollX},${point.y - scrollY}`)
          .join(" "),
      );
      path.style.display = "";
      hasVisibleInk = true;
    }
    overlay.regionInkSvg.style.display = hasVisibleInk ? "block" : "none";
  };

  const annotationInkPoints = () => {
    if (!pendingAnnotation) return marqueePoints;
    const scrollX = globalThis.scrollX || 0;
    const scrollY = globalThis.scrollY || 0;
    return pendingAnnotation.pagePoints.map((point) => ({
      x: point.x - scrollX,
      y: point.y - scrollY,
    }));
  };

  const showAnnotationInkOnly = () => {
    createOverlay();
    if (!overlay) return;
    for (const name of ["margin", "border", "padding", "content", "badge", "marqueeBox"]) {
      overlay[name].style.display = "none";
    }
    for (const outline of overlay.selectionOutlines) outline.style.display = "none";
    for (const outline of overlay.regionOutlines) outline.style.display = "none";
    overlay.regionInkSvg.style.display = "none";
    const points = annotationInkPoints();
    overlay.strokePath.setAttribute(
      "points",
      points.map((point) => `${point.x},${point.y}`).join(" "),
    );
    overlay.strokeSvg.style.display = points.length > 1 ? "block" : "none";
    overlay.shield.style.display = enabled ? "block" : "none";
  };

  const displaySelectorFor = (element) => {
    if (!element) return null;
    const reference = selectedReferences.find((candidate) => candidate.element === element);
    if (reference?.baseline?.selector) return reference.baseline.selector;
    if (element.id && element.id.length <= maxSelectorValueCharacters) return `#${cssEscape(element.id)}`;
    return classSelector(element) || element.localName || "element";
  };

  const composerState = () => ({
    visible: false,
    mode: interactionMode,
    tag_name: selectedBaseline?.tag_name || (regionReferences.length ? "region" : null),
    selection_count: selectedReferences.length + regionReferences.length,
    selectors: selectedReferences.map((reference) => reference.baseline?.selector).filter(Boolean)
      .concat(regionReferences.map((region) => regionSnapshotFor(region).selector)),
    hovered_selector: displaySelectorFor(hoveredElement),
    can_copy: Boolean(selectedReferences.length && selectedBaseline) || regionReferences.length > 0,
    focused: false,
    annotation_phase: annotationPhase,
  });

  const refreshOverlay = () => {
    if (overlayFrame) cancelAnimationFrame(overlayFrame);
    overlayFrame = 0;
    if (!enabled || captureHidden) {
      hideOverlay();
      return;
    }
    createOverlay();
    if (["drawing", "ink_only", "capturing"].includes(annotationPhase)) {
      showAnnotationInkOnly();
      return;
    }
    if (hoveredElement && !hoveredElement.isConnected) hoveredElement = null;
    const selected = resolveSelectedElement();
    refreshSelectedOutlines();
    const element = hoveredElement?.isConnected ? hoveredElement : selected;
    if (!element) {
      // No hover/active element: hide only the hover feedback. Selection and
      // region outlines must stay visible (a freshly drawn region would
      // otherwise vanish until the next selection forces a refresh).
      hideHoverFeedback();
      return;
    }

    const rect = element.getBoundingClientRect();
    // Cursor-style hover: a single accent veil + outline over the element
    // bounds, tinted with the color this pick would take. The
    // margin/border/padding boxes stay hidden.
    // An already-selected element keeps its own color under the hover veil;
    // only a fresh target previews the next pick's color.
    const existing = selectedReferences.find((reference) => reference.element === element);
    const tint = existing ? selectionColor(existing.colorIndex || 0) : upcomingColor();
    overlay.content.style.background = colorWithAlpha(tint, 0.13);
    overlay.content.style.outline = `1.5px solid ${tint}`;
    overlay.badge.style.background = tint;
    overlay.badge.style.color = contrastingTextColor(tint);
    place(overlay.content, { x: rect.x, y: rect.y, width: rect.width, height: rect.height });
    positionHoverBadge(element, rect, selected);
  };

  const positionHoverBadge = (element, rect, selected) => {
    if (element === selected) {
      overlay.badge.style.display = "none";
      return;
    }
    overlay.badge.textContent = truncateMiddle(elementLabel(element), 48);
    overlay.badge.style.display = "block";
    const badgeRect = overlay.badge.getBoundingClientRect();
    const badgeWidth = badgeRect.width || 120;
    const badgeHeight = badgeRect.height || 24;
    const left = Math.max(8, Math.min(rect.right - badgeWidth, globalThis.innerWidth - badgeWidth - 8));
    overlay.badge.style.left = `${left}px`;
    overlay.badge.style.top = `${rect.y > badgeHeight + 8 ? rect.y - badgeHeight - 5 : rect.y + 5}px`;
  };

  const scheduleOverlayRefresh = () => {
    if (overlayFrame) return;
    overlayFrame = requestAnimationFrame(refreshOverlay);
  };

  const refreshAfterMutation = (emitRecoveredSelection = false, observedMutation = false) => {
    refreshScheduled = false;
    const editsChanged = editStateNeedsEmit;
    editStateNeedsEmit = false;
    let identityChanged = false;
    if (selectionIdentityNeedsRefresh && selectedElement?.isConnected && selectedBaseline) {
      const selectors = selectorsFor(selectedElement);
      if (!selectors.length) {
        restoreAll();
        const index = selectedReferences.indexOf(activeReference);
        if (index >= 0) selectedReferences.splice(index, 1);
        setActiveReference(selectedReferences[selectedReferences.length - 1]);
        hoveredElement = null;
        selectionIdentityNeedsRefresh = false;
        selectionRecoveryAttemptsRemaining = 0;
        cancelSelectionRecovery();
        revision += 1;
        scheduleMutationEmission();
        scheduleOverlayRefresh();
        return;
      }
      identityChanged = selectors[0] !== selectedBaseline.selector
        || selectors.length !== selectedBaseline.selectors.length
        || selectors.some((selector, index) => selector !== selectedBaseline.selectors[index]);
      selectedBaseline = { ...selectedBaseline, selector: selectors[0], selectors };
      updateActiveReference();
    }
    selectionIdentityNeedsRefresh = false;
    const previous = selectedElement;
    const current = resolveSelectedElement(true);
    if (previous && previous !== current) restoreAndForgetElement(previous);
    if (current) {
      applyEditsTo(current);
      selectedIdentity = identityFor(current);
      updateActiveReference();
      selectionRecoveryAttemptsRemaining = 0;
    } else if (previous) {
      selectionRecoveryAttemptsRemaining = maxSelectionRecoveryAttempts;
    }
    if (observedMutation || previous !== current || identityChanged || editsChanged || (emitRecoveredSelection && current)) {
      revision += 1;
      scheduleMutationEmission();
    }
    scheduleOverlayRefresh();
  };

  const scheduleMutationRefresh = () => {
    if (refreshScheduled) return;
    refreshScheduled = true;
    const enqueue = globalThis.queueMicrotask || ((work) => Promise.resolve().then(work));
    enqueue(() => refreshAfterMutation(false, true));
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
    if (mutation.type === "characterData") {
      if (!nodeContains(selected, mutation.target)) return false;
      if (capturePageTextMutation(selected)) editStateNeedsEmit = true;
      return true;
    }
    if (mutation.type === "attributes") {
      if (mutation.target === selected && mutation.attributeName === "style") {
        capturePageStyleMutation(selected);
        return true;
      }
      if (!selectorAttributes.has(mutation.attributeName || "")) return false;
      if (mutation.target === selected || nodeContains(mutation.target, selected)) {
        selectionIdentityNeedsRefresh = true;
        return true;
      }
      return false;
    }
    if (mutation.type !== "childList") return false;
    if (nodeContains(selected, mutation.target)) {
      if (capturePageTextMutation(selected)) editStateNeedsEmit = true;
      return true;
    }
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
    if (hoveredElement && mutations.some((mutation) => mutation.type === "childList"
      && Array.from(mutation.removedNodes).some((node) => nodeContains(node, hoveredElement)))) {
      hoveredElement = null;
      scheduleOverlayRefresh();
    }
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

  const resetPendingAnnotation = (notifyNative) => {
    const id = pendingAnnotation?.id || pendingPointer?.annotationID || null;
    pendingAnnotation = null;
    pendingPointer = null;
    marqueeActive = false;
    marqueePoints = [];
    annotationPhase = "idle";
    if (overlay) {
      overlay.marqueeBox.style.display = "none";
      overlay.strokeSvg.style.display = "none";
      overlay.strokePath.setAttribute("points", "");
    }
    if (notifyNative && id) {
      try { handler?.postMessage({ type: "annotation_cancelled", id }); } catch (_) {}
    }
    scheduleOverlayRefresh();
    return id;
  };

  const clearSelection = () => {
    resetPendingAnnotation(true);
    draft = null;
    if (!selectedReferences.length && !regionReferences.length) return snapshot();
    restoreAll();
    selectedReferences.length = 0;
    regionReferences.length = 0;
    // colorSequence deliberately keeps counting: elements and regions share
    // one rotation, and a cleared prompt continues from the last used color
    // instead of restarting at blue.
    setActiveReference(null);
    hoveredElement = null;
    hoveredSelectionIndex = null;
    selectionIdentityNeedsRefresh = false;
    selectionRecoveryAttemptsRemaining = 0;
    captureSelectionValid = true;
    cancelSelectionRecovery();
    revision += 1;
    scheduleOverlayRefresh();
    return emit();
  };

  const removeSelectionAt = (index) => {
    // Regions are appended after element selections in snapshots, so indexes
    // past the element count address regionReferences.
    if (Number.isInteger(index) && index >= selectedReferences.length
        && index < selectedReferences.length + regionReferences.length) {
      regionReferences.splice(index - selectedReferences.length, 1);
      hoveredSelectionIndex = null;
      revision += 1;
      scheduleOverlayRefresh();
      return emit();
    }
    if (!Number.isInteger(index) || index < 0 || index >= selectedReferences.length) {
      return snapshot();
    }
    const reference = selectedReferences[index];
    if (reference === activeReference && edits.size) restoreAll();
    selectedReferences.splice(index, 1);
    hoveredSelectionIndex = null;
    if (draft?.reference === reference) {
      draft = null;
      if (overlay) {
        overlay.bubble.removeAttribute("data-open");
        overlay.bubble.style.display = "none";
      }
    }
    if (reference === activeReference) {
      setActiveReference(selectedReferences[selectedReferences.length - 1]);
      selectionIdentityNeedsRefresh = false;
      selectionRecoveryAttemptsRemaining = 0;
      cancelSelectionRecovery();
    }
    revision += 1;
    // At once: the other pins renumber in the same frame the chat's chips do.
    refreshOverlay();
    return emit();
  };

  const selectionIndex = (selection) => {
    if (typeof selection !== "string") return Number(selection);
    const elementIndex = selectedReferences.findIndex(
      (reference) => reference.baseline?.selector === selection,
    );
    if (elementIndex >= 0) return elementIndex;
    const regionIndex = regionReferences.findIndex(
      (region) => regionSnapshotFor(region).selector === selection,
    );
    return regionIndex >= 0 ? selectedReferences.length + regionIndex : -1;
  };

  const selectElement = (element, stack = false) => {
    if (!element || element === overlayHost || overlayHost?.contains(element)) return snapshot();
    annotationPhase = "idle";
    cancelSelectionRecovery();
    cancelMutationEmission();
    const elementIndex = selectedReferences.findIndex((reference) => reference.element === element);
    if (elementIndex === selectedReferences.length - 1 && selectedElement === element && selectedBaseline
        && (stack || selectedReferences.length === 1)) {
      hoveredElement = null;
      scheduleOverlayRefresh();
      return snapshot();
    }
    const validatedBaseline = baselineFor(element);
    if (!validatedBaseline) return snapshot();
    if (edits.size) restoreAll();
    if (!stack) selectedReferences.length = 0;
    let referenceIndex = selectedReferences.findIndex((reference) => reference.element === element);
    if (referenceIndex < 0) {
      referenceIndex = selectedReferences.findIndex(
        (reference) => reference.baseline?.selector === validatedBaseline.selector,
      );
    }
    let reference;
    if (referenceIndex >= 0) {
      [reference] = selectedReferences.splice(referenceIndex, 1);
      reference.element = element;
      reference.baseline = validatedBaseline;
      reference.identity = identityFor(element);
    } else {
      reference = {
        element,
        baseline: validatedBaseline,
        identity: identityFor(element),
        colorIndex: colorSequence++,
      };
    }
    selectedReferences.push(reference);
    setActiveReference(reference);
    selectionIdentityNeedsRefresh = false;
    selectionRecoveryAttemptsRemaining = 0;
    captureSelectionValid = true;
    hoveredElement = null;
    revision += 1;
    scheduleOverlayRefresh();
    return emit();
  };

  // A short name for an element: its tag and its id or first class (`h1#title`, `p.lede`).
  const elementLabel = (element) => {
    const tag = element?.localName || "element";
    if (element?.id && element.id.length <= 40) return `${tag}#${element.id}`;
    const first = typeof element?.className === "string" ? element.className.trim().split(/\s+/)[0] : "";
    return first && first.length <= 40 ? `${tag}.${first}` : tag;
  };

  // Whether a pointer event is over a pick's thread card: it belongs to the card (its reply's text,
  // Resolve), never to picking or to the page.
  const overThread = (event) => Boolean(overlay?.threadCards.some((card) => {
    if (card.style.display === "none") return false;
    const rect = card.getBoundingClientRect();
    return rect.width > 0 && event.clientX >= rect.left && event.clientX <= rect.right
      && event.clientY >= rect.top && event.clientY <= rect.bottom;
  }));

  const bubbleFocused = () => Boolean(draft && overlay && overlay.shadow.activeElement === overlay.field);

  // Whether a pointer event is over the open bubble: it then belongs to the bubble (caret, text
  // selection), never to picking or to the page.
  const overBubble = (event) => {
    if (overThread(event)) return true;
    if (!draft || !overlay || overlay.bubble.style.display === "none") return false;
    const rect = overlay.bubble.getBoundingClientRect();
    return rect.width > 0 && event.clientX >= rect.left && event.clientX <= rect.right
      && event.clientY >= rect.top && event.clientY <= rect.bottom;
  };

  const fitField = () => {
    if (!overlay) return;
    const field = overlay.field;
    field.style.height = "auto";
    field.style.height = `${Math.min(128, Math.max(22, field.scrollHeight || 22))}px`;
  };

  // Opens `reference`'s bubble: a new pick (not added until Return) or an added one to edit.
  const openDraft = (reference, isNew) => {
    createOverlay();
    draft = { reference, isNew };
    const element = referenceElement(reference, false);
    const tint = selectionColor(reference.colorIndex || 0);
    overlay.bubbleNumber.textContent = String(pickNumber(reference));
    overlay.bubbleNumber.style.background = tint;
    overlay.bubbleNumber.style.color = contrastingTextColor(tint);
    const words = (element?.textContent || "").replace(/\s+/g, " ").trim();
    overlay.bubbleWhat.textContent = words
      ? `${elementLabel(element)} · ${truncateMiddle(words, 56)}`
      : elementLabel(element);
    overlay.field.value = reference.comment || "";
    overlay.field.placeholder = strings.placeholder;
    overlay.field.setAttribute("aria-label", strings.placeholder);
    overlay.bubbleHint.textContent = (isNew ? strings.add : strings.save) + (sendAvailable ? ` · ${strings.send}` : "");
    overlay.bubble.removeAttribute("data-open");
    // Restart the enter animation for each bubble, also when it moves from one pick to the next.
    void overlay.bubble.offsetWidth;
    overlay.bubble.setAttribute("data-open", "");
    hoveredElement = null;
    refreshOverlay();
    fitField();
    try { overlay.field.focus({ preventScroll: true }); } catch (_) { overlay.field.focus(); }
    const end = overlay.field.value.length;
    try { overlay.field.setSelectionRange(end, end); } catch (_) {}
  };

  // Closes the open bubble. `keep`: the pick is added (or its edit saved) with the typed comment;
  // otherwise a new pick is dropped and an added one keeps its old comment.
  const finishDraft = (keep) => {
    if (!draft || !overlay) return snapshot();
    const { reference, isNew } = draft;
    const comment = bounded(overlay.field.value.trim(), maxCommentCharacters);
    draft = null;
    overlay.bubble.removeAttribute("data-open");
    overlay.bubble.style.display = "none";
    try { overlay.field.blur(); } catch (_) {}
    if (keep) {
      reference.comment = comment;
      reference.added = true;
    } else if (isNew) {
      const index = selectedReferences.indexOf(reference);
      if (index >= 0) return removeSelectionAt(index);
    } else {
      refreshOverlay();
      return snapshot();
    }
    revision += 1;
    refreshOverlay();
    return emit();
  };

  // A click on `element`: it first settles the open bubble (a typed comment, or an edit, is kept;
  // an empty new pick is dropped), then opens the bubble for the element: its own when it is
  // already a pick, else a new pick's.
  const pickElement = (element) => {
    if (!element || element === overlayHost || overlayHost?.contains(element)) return snapshot();
    if (draft) {
      if (referenceElement(draft.reference, false) === element) {
        try { overlay.field.focus({ preventScroll: true }); } catch (_) {}
        return snapshot();
      }
      finishDraft(!draft.isNew || overlay.field.value.trim().length > 0);
    }
    const existing = selectedReferences.find((reference) => reference.element === element && reference.added !== false);
    if (existing) {
      openDraft(existing, false);
      return snapshot();
    }
    const before = selectedReferences.length;
    selectElement(element, true);
    const reference = selectedReferences[selectedReferences.length - 1];
    if (!reference || reference.element !== element) return snapshot();
    if (selectedReferences.length > before) {
      reference.added = false;
      reference.comment = "";
    }
    openDraft(reference, reference.added === false);
    return snapshot();
  };

  // Keys while the bubble has focus: Return adds, Shift-Return is a new line, Escape cancels,
  // Delete on an emptied comment removes an added pick. None reaches the page.
  const onBubbleKey = (event) => {
    event.stopImmediatePropagation();
    const composing = event.isComposing || event.keyCode === 229;
    if (event.key === "Enter" && (event.metaKey || event.ctrlKey) && !event.shiftKey && !composing) {
      // Command-Return: adds the pick, then asks the app to send it to the agent as a thread. Only a
      // real key sends; without threads it adds the pick as Return does.
      event.preventDefault();
      const reference = draft.reference;
      finishDraft(true);
      const selector = reference.baseline?.selector;
      if (sendAvailable && event.isTrusted && selector && reference.added) {
        try { handler?.postMessage({ type: "send_requested", selector }); } catch (_) {}
      }
    } else if (event.key === "Enter" && !event.shiftKey && !composing) {
      event.preventDefault();
      finishDraft(true);
    } else if (event.key === "Escape" && !composing) {
      event.preventDefault();
      finishDraft(false);
    } else if ((event.key === "Backspace" || event.key === "Delete") && !draft.isNew && overlay.field.value === "") {
      event.preventDefault();
      const index = selectedReferences.indexOf(draft.reference);
      draft = null;
      overlay.bubble.removeAttribute("data-open");
      overlay.bubble.style.display = "none";
      if (index >= 0) removeSelectionAt(index);
      refreshOverlay();
    }
  };

  // Text events from the bubble stop at the document: the page never sees what is typed in it.
  const onBubbleText = (event) => {
    if (!enabled || !bubbleFocused()) return;
    event.stopImmediatePropagation();
    if (event.type === "input") fitField();
  };

  const onPointerMove = (event) => {
    if (!enabled || captureHidden || pendingAnnotation) return;
    if (overBubble(event)) {
      if (hoveredElement) {
        hoveredElement = null;
        scheduleOverlayRefresh();
      }
      return;
    }
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();
    // The composer region is pointer-dead for the page: no hover, and the
    // shield must not advertise its crosshair there (WebKit derives the
    // cursor from the hovered element's CSS even under native overlays).
    const insideComposer = composerFrame
      && event.clientX >= composerFrame.x && event.clientX <= composerFrame.x + composerFrame.width
      && event.clientY >= composerFrame.y && event.clientY <= composerFrame.y + composerFrame.height;
    if (overlay) {
      overlay.shield.style.cursor = insideComposer ? "default" : "crosshair";
    }
    if (insideComposer) {
      if (hoveredElement) {
        hoveredElement = null;
        scheduleOverlayRefresh();
      }
      return;
    }
    if (pendingPointer) {
      const dx = event.clientX - pendingPointer.x;
      const dy = event.clientY - pendingPointer.y;
      if (marqueeActive || Math.hypot(dx, dy) > marqueeThresholdPixels) {
        if (!marqueeActive) {
          if (!pendingPointer.annotationID) {
            interactionMode = "draw";
            pendingPointer.annotationID = String(++annotationSequence);
            annotationPhase = "drawing";
            try { handler?.postMessage({ type: "interaction_mode_changed", mode: "draw" }); } catch (_) {}
            try {
              handler?.postMessage({ type: "annotation_drawing", id: pendingPointer.annotationID });
            } catch (_) {}
          }
          marqueePoints = [{ x: pendingPointer.x, y: pendingPointer.y }];
        }
        marqueeActive = true;
        hoveredElement = null;
        marqueePoints.push({ x: event.clientX, y: event.clientY });
        updateMarqueeBox();
        return;
      }
    }
    if (interactionMode === "draw") return;
    const candidate = elementUnderPoint(event.clientX, event.clientY);
    if (!candidate || candidate === hoveredElement) return;
    hoveredElement = candidate;
    scheduleOverlayRefresh();
  };

  // The captured region is the bounding box of the whole freehand stroke,
  // not just its endpoints, so circling or scribbling over an area crops it.
  const boundsForPoints = (points) => {
    let minX = Infinity; let minY = Infinity; let maxX = -Infinity; let maxY = -Infinity;
    for (const point of points) {
      minX = Math.min(minX, point.x);
      minY = Math.min(minY, point.y);
      maxX = Math.max(maxX, point.x);
      maxY = Math.max(maxY, point.y);
    }
    if (!Number.isFinite(minX)) return { x: 0, y: 0, width: 0, height: 0 };
    return { x: minX, y: minY, width: maxX - minX, height: maxY - minY };
  };

  const marqueeBounds = () => boundsForPoints(marqueePoints);

  const annotationCaptureDescriptor = (id) => {
    if (!pendingAnnotation || pendingAnnotation.id !== String(id || "")) return null;
    const scrollX = globalThis.scrollX || 0;
    const scrollY = globalThis.scrollY || 0;
    const viewportPoints = pendingAnnotation.pagePoints.map((point) => ({
      x: point.x - scrollX,
      y: point.y - scrollY,
    }));
    return {
      id: pendingAnnotation.id,
      stroke_bounds: boundsForPoints(viewportPoints),
      viewport: { width: globalThis.innerWidth || 0, height: globalThis.innerHeight || 0 },
      scroll_x: scrollX,
      scroll_y: scrollY,
    };
  };

  const updateMarqueeBox = () => {
    createOverlay();
    if (!overlay) return;
    const tint = upcomingColor();
    overlay.marqueeBox.style.border = `1.5px dashed ${colorWithAlpha(tint, 0.85)}`;
    overlay.marqueeBox.style.background = colorWithAlpha(tint, 0.07);
    overlay.strokePath.setAttribute("stroke", tint);
    overlay.marqueeBox.style.display = "none";
    overlay.strokePath.setAttribute(
      "points",
      marqueePoints.map((point) => `${point.x},${point.y}`).join(" "),
    );
    overlay.strokeSvg.style.display = "block";
    hideHoverFeedback();
    showAnnotationInkOnly();
  };

  const hideHoverFeedback = () => {
    if (!overlay) return;
    overlay.content.style.display = "none";
    overlay.badge.style.display = "none";
  };

  const onPointerLeave = () => {
    if (!enabled || captureHidden || !hoveredElement) return;
    hoveredElement = null;
    scheduleOverlayRefresh();
  };

  const elementUnderPoint = (x, y) => {
    const shield = overlay?.shield;
    shield?.style.setProperty("pointer-events", "none", "important");
    overlayHost?.style.setProperty("pointer-events", "none", "important");
    try {
      const candidate = document.elementFromPoint(x, y);
      return candidate === overlayHost || overlayHost?.contains(candidate) ? null : candidate;
    } finally {
      overlayHost?.style.setProperty("pointer-events", "auto", "important");
      shield?.style.setProperty("pointer-events", "auto", "important");
    }
  };

  // Pointer protocol: pointerdown arms; drag past the threshold draws a
  // marquee whose pointerup captures a region; a sub-threshold pointerup
  // selects the element. Real pointer sequences suppress the trailing click;
  // a standalone synthetic click still selects (fallback for tests/automation).
  const onPointerDown = (event) => {
    if (!enabled || captureHidden || pendingAnnotation) return;
    if (overBubble(event)) return;
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();
    if (event.button !== 0) return;
    const annotationID = interactionMode === "draw" ? String(++annotationSequence) : null;
    pendingPointer = {
      x: event.clientX,
      y: event.clientY,
      shift: event.shiftKey === true,
      annotationID,
    };
    marqueeActive = false;
    if (annotationID) {
      annotationPhase = "drawing";
      try { handler?.postMessage({ type: "annotation_drawing", id: annotationID }); } catch (_) {}
      scheduleOverlayRefresh();
      showAnnotationInkOnly();
    }
  };

  const onPointerUp = (event) => {
    if (!enabled || captureHidden || pendingAnnotation) return;
    if (overBubble(event) && !pendingPointer) return;
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();
    const armed = pendingPointer;
    const wasMarquee = marqueeActive;
    pendingPointer = null;
    marqueeActive = false;
    if (!armed) return;
    suppressClicksUntil = (globalThis.performance?.now?.() || 0) + 500;
    if (overlay) {
      overlay.marqueeBox.style.display = "none";
    }
    if (wasMarquee) {
      marqueePoints.push({ x: event.clientX, y: event.clientY });
      updateMarqueeBox();
      const bounds = marqueeBounds();
      finalizeRegion(bounds, armed.annotationID);
      return;
    }
    // Draw mode never element-selects; a tap there is a no-op.
    if (interactionMode === "draw") {
      marqueePoints = [];
      annotationPhase = "idle";
      interactionMode = "select";
      if (overlay) {
        overlay.strokeSvg.style.display = "none";
        overlay.strokePath.setAttribute("points", "");
      }
      try { handler?.postMessage({ type: "annotation_cancelled", id: armed.annotationID }); } catch (_) {}
      return;
    }
    // Clicks always stack: every click opens a comment bubble for its element
    // (pickElement); an added pick leaves through its bubble or the chat.
    const candidate = elementUnderPoint(armed.x, armed.y);
    if (candidate) pickElement(candidate);
  };

  const finalizeRegion = (rect, id) => {
    // Accept deliberate strokes in any direction, including horizontal or
    // vertical marks whose bounding box has a zero-sized minor axis.
    if (!id || Math.max(rect.width, rect.height) < 8) {
      annotationPhase = "idle";
      interactionMode = "select";
      marqueePoints = [];
      if (overlay) {
        overlay.strokeSvg.style.display = "none";
        overlay.strokePath.setAttribute("points", "");
      }
      try { handler?.postMessage({ type: "annotation_cancelled", id }); } catch (_) {}
      return;
    }
    const scrollX = globalThis.scrollX || 0;
    const scrollY = globalThis.scrollY || 0;
    pendingAnnotation = {
      id,
      pagePoints: marqueePoints.map((point) => ({ x: point.x + scrollX, y: point.y + scrollY })),
      colorIndex: colorSequence,
    };
    marqueePoints = [];
    annotationPhase = "ink_only";
    hoveredElement = null;
    scheduleOverlayRefresh();
    const request = annotationCaptureDescriptor(id);
    try { handler?.postMessage({ type: "annotation_capture_requested", request }); } catch (_) {}
  };

  const onClickFallback = (event) => {
    if (!enabled || captureHidden) return;
    if (overBubble(event)) return;
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();
    if (event.button !== 0) return;
    if ((globalThis.performance?.now?.() || 0) < suppressClicksUntil) return;
    if (interactionMode === "draw") return;
    const candidate = elementUnderPoint(event.clientX, event.clientY);
    if (candidate) pickElement(candidate);
  };

  const blockPageGesture = (event) => {
    if (!enabled || captureHidden) return;
    if (overBubble(event)) return;
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();
  };

  const onKeyDown = (event) => {
    if (!enabled || captureHidden) return;
    if (bubbleFocused()) return onBubbleKey(event);
    if (event.key !== "Escape") return;
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();
    if (pendingAnnotation || pendingPointer?.annotationID) {
      resetPendingAnnotation(true);
      interactionMode = "select";
      return;
    }
    // An open bubble without focus (the page took it): Escape closes it as it would inside.
    if (draft) {
      finishDraft(false);
      return;
    }
    // Escape with no bubble open leaves design mode; added picks stay in the chat's composer.
    handler?.postMessage({ type: "exit_requested" });
  };

  const bubbleTextEvents = ["keyup", "keypress", "beforeinput", "input", "compositionstart", "compositionend", "paste", "copy", "cut"];

  const installListeners = () => {
    document.addEventListener("pointermove", onPointerMove, true);
    document.addEventListener("pointerleave", onPointerLeave, true);
    document.addEventListener("pointerdown", onPointerDown, true);
    document.addEventListener("pointerup", onPointerUp, true);
    document.addEventListener("click", onClickFallback, true);
    overlay?.shield.addEventListener("pointermove", onPointerMove, true);
    overlay?.shield.addEventListener("pointerleave", onPointerLeave, true);
    overlay?.shield.addEventListener("pointerdown", onPointerDown, true);
    overlay?.shield.addEventListener("pointerup", onPointerUp, true);
    overlay?.shield.addEventListener("click", onClickFallback, true);
    for (const name of ["mousedown", "mouseup", "dblclick", "contextmenu"]) {
      document.addEventListener(name, blockPageGesture, true);
      overlay?.shield.addEventListener(name, blockPageGesture, true);
    }
    document.addEventListener("keydown", onKeyDown, true);
    for (const name of bubbleTextEvents) document.addEventListener(name, onBubbleText, true);
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
    document.removeEventListener("pointerleave", onPointerLeave, true);
    document.removeEventListener("pointerdown", onPointerDown, true);
    document.removeEventListener("pointerup", onPointerUp, true);
    document.removeEventListener("click", onClickFallback, true);
    overlay?.shield.removeEventListener("pointermove", onPointerMove, true);
    overlay?.shield.removeEventListener("pointerleave", onPointerLeave, true);
    overlay?.shield.removeEventListener("pointerdown", onPointerDown, true);
    overlay?.shield.removeEventListener("pointerup", onPointerUp, true);
    overlay?.shield.removeEventListener("click", onClickFallback, true);
    for (const name of ["mousedown", "mouseup", "dblclick", "contextmenu"]) {
      document.removeEventListener(name, blockPageGesture, true);
      overlay?.shield.removeEventListener(name, blockPageGesture, true);
    }
    pendingPointer = null;
    marqueeActive = false;
    marqueePoints = [];
    document.removeEventListener("keydown", onKeyDown, true);
    for (const name of bubbleTextEvents) document.removeEventListener(name, onBubbleText, true);
    globalThis.removeEventListener("scroll", scheduleOverlayRefresh, true);
    globalThis.removeEventListener("resize", scheduleOverlayRefresh, true);
    observer?.disconnect();
    observer = null;
    if (overlayFrame) cancelAnimationFrame(overlayFrame);
    overlayFrame = 0;
    cancelSelectionRecovery();
    cancelMutationEmission();
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
      if (enabled || selectedReferences.length || regionReferences.length || edits.size || overlayHost) revision += 1;
      enabled = false;
      removeListeners();
      restoreAll();
      selectedReferences.length = 0;
      regionReferences.length = 0;
      pendingAnnotation = null;
      annotationPhase = "idle";
      draft = null;
      setActiveReference(null);
      selectionIdentityNeedsRefresh = false;
      selectionRecoveryAttemptsRemaining = 0;
      cancelSelectionRecovery();
      hoveredElement = null;
      hoveredSelectionIndex = null;
      overlayHost?.remove();
      overlayHost = null;
      overlay = null;
      captureHidden = false;
      captureSelectionValid = true;
      lastMutationEmissionAt = 0;
      lastMutationEmissionSignature = "";
      const finalSnapshot = snapshot();
      try { delete globalThis.__cmuxDesignMode; } catch (_) { globalThis.__cmuxDesignMode = undefined; }
      return finalSnapshot;
    },

    snapshot,

    clearSelection() {
      return clearSelection();
    },

    // The bubble's and thread cards' words in the app's language: `{placeholder, add, save, send,
    // sending, sent, answered, failed, resolve}`.
    configure(words) {
      for (const key of ["placeholder", "add", "save", "send", "sending", "sent", "answered", "failed", "resolve"]) {
        if (typeof words?.[key] === "string" && words[key]) strings[key] = bounded(words[key], 120);
      }
      return snapshot();
    },

    // The open bubble's text, as typed (automation and captures; a person types into the field).
    draft(text) {
      if (!draft || !overlay) return snapshot();
      overlay.field.value = bounded(String(text ?? ""), maxCommentCharacters);
      fitField();
      positionBubble();
      return snapshot();
    },

    // Return in the open bubble: adds the pick with its comment.
    commit() {
      return finishDraft(true);
    },

    setComposerFrame(x, y, width, height) {
      if ([x, y, width, height].every((value) => Number.isFinite(value)) && width > 0 && height > 0) {
        composerFrame = { x, y, width, height };
        if (hoveredElement) {
          hoveredElement = null;
          scheduleOverlayRefresh();
        }
      } else {
        composerFrame = null;
      }
      return snapshot();
    },

    clearHover() {
      if (hoveredElement) {
        hoveredElement = null;
        scheduleOverlayRefresh();
      }
      return snapshot();
    },

    flashSelection(index) {
      const position = Number(index);
      if (!Number.isInteger(position) || position < 0) return snapshot();
      createOverlay();
      if (position < selectedReferences.length) {
        const element = referenceElement(selectedReferences[position], false);
        try { element?.scrollIntoView({ block: "nearest" }); } catch (_) {}
        refreshOverlay();
        const outline = overlay?.selectionOutlines[position];
        try {
          outline?.animate?.(
            [
              { boxShadow: "0 0 0 6px rgba(10, 132, 255, 0.55)" },
              { boxShadow: "0 0 0 0 rgba(10, 132, 255, 0)" },
            ],
            { duration: 650 }
          );
        } catch (_) {}
      } else if (position < selectedReferences.length + regionReferences.length) {
        refreshOverlay();
        const outline = overlay?.regionOutlines[position - selectedReferences.length];
        try {
          outline?.animate?.(
            [
              { boxShadow: "0 0 0 6px rgba(10, 132, 255, 0.55)" },
              { boxShadow: "0 0 0 0 rgba(10, 132, 255, 0)" },
            ],
            { duration: 650 }
          );
        } catch (_) {}
      }
      return snapshot();
    },

    setSelectionHover(selection) {
      const position = selection == null ? null : selectionIndex(selection);
      const selectionCount = selectedReferences.length + regionReferences.length;
      hoveredSelectionIndex = Number.isInteger(position) && position >= 0 && position < selectionCount
        ? position
        : null;
      hoveredElement = null;
      refreshOverlay();
      return snapshot();
    },

    setMode(value) {
      const mode = value === "draw" ? "draw" : "select";
      if (mode !== interactionMode) {
        resetPendingAnnotation(true);
        interactionMode = mode;
        pendingPointer = null;
        marqueeActive = false;
        marqueePoints = [];
        hoveredElement = null;
        hoveredSelectionIndex = null;
        if (overlay) {
          overlay.marqueeBox.style.display = "none";
          overlay.strokeSvg.style.display = "none";
          overlay.strokePath.setAttribute("points", "");
        }
        scheduleOverlayRefresh();
      }
      return snapshot();
    },

    select(selector, stack) {
      let element = null;
      try { element = document.querySelector(String(selector || "")); } catch (_) {}
      return element ? selectElement(element, stack === true) : snapshot();
    },

    composerState,

    removeSelection(selection) {
      return removeSelectionAt(selectionIndex(selection));
    },

    // Whether Command-Return sends a pick to the agent as a comment thread (the app's chat keeps them).
    setSendAvailable(available) {
      sendAvailable = available === true;
      if (draft && overlay) {
        overlay.bubbleHint.textContent = (draft.isNew ? strings.add : strings.save) + (sendAvailable ? ` · ${strings.send}` : "");
      }
      return sendAvailable;
    },

    // The thread of the pick at `selection` (its selector): `{state, reply}` with state `sending`,
    // `sent`, `answered` or `failed`, shown in a card beside its pin; null takes the card away.
    // False when no pick has that selector.
    setThread(selection, value) {
      const index = selectionIndex(selection);
      const reference = Number.isInteger(index) && index >= 0 ? selectedReferences[index] : null;
      if (!reference) return false;
      const states = ["sending", "sent", "answered", "failed"];
      reference.thread = value && states.includes(value.state)
        ? { state: value.state, reply: bounded(String(value.reply ?? ""), maxReplyCharacters) }
        : null;
      refreshOverlay();
      return true;
    },

    // A kept comment thread put back on its element (the selector it was picked at): an added pick
    // with `comment` and the thread card `value`, as when it was sent. False when no element has
    // that selector any more (the page changed), so the app knows the thread has no place here.
    restoreThread(selector, comment, value) {
      selector = String(selector || "");
      let element = null;
      try { element = document.querySelector(selector); } catch (_) {}
      if (!element || element === overlayHost || overlayHost?.contains(element)) return false;
      let reference = selectedReferences.find((candidate) => candidate.baseline?.selector === selector);
      if (!reference) {
        const baseline = baselineFor(element);
        // Another selector now names the element: its card would not be the thread's.
        if (!baseline || baseline.selector !== selector) return false;
        reference = { element, baseline, identity: identityFor(element), colorIndex: colorSequence++ };
        selectedReferences.push(reference);
      }
      reference.comment = bounded(String(comment ?? "").trim(), maxCommentCharacters);
      reference.added = true;
      api.setThread(selector, value);
      revision += 1;
      emit();
      return true;
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

    prepareAnnotationCapture(id) {
      const descriptor = annotationCaptureDescriptor(id);
      if (!descriptor) return null;
      annotationPhase = "capturing";
      showAnnotationInkOnly();
      // Synchronize page layout before WebKit snapshots the ink-only frame.
      document.documentElement.getBoundingClientRect();
      return annotationCaptureDescriptor(id);
    },

    annotationCaptureDescriptor(id) {
      return annotationCaptureDescriptor(id);
    },

    completeAnnotationCapture(
      id,
      x,
      y,
      width,
      height,
      expectedScrollX,
      expectedScrollY,
      expectedViewportWidth,
      expectedViewportHeight,
    ) {
      const descriptor = annotationCaptureDescriptor(id);
      const values = [x, y, width, height, expectedScrollX, expectedScrollY,
        expectedViewportWidth, expectedViewportHeight];
      if (!descriptor || !values.every(Number.isFinite)
          || width <= 0 || height <= 0
          || descriptor.scroll_x !== expectedScrollX
          || descriptor.scroll_y !== expectedScrollY
          || descriptor.viewport.width !== expectedViewportWidth
          || descriptor.viewport.height !== expectedViewportHeight) {
        return null;
      }
      regionReferences.push({
        id: pendingAnnotation.id,
        pageX: x + expectedScrollX,
        pageY: y + expectedScrollY,
        width,
        height,
        pagePoints: pendingAnnotation.pagePoints.map((point) => ({ ...point })),
        colorIndex: pendingAnnotation.colorIndex,
      });
      // Keep the prompt and overlay bounded during a long drawing session.
      if (regionReferences.length > maxAnnotationReferences) {
        regionReferences.splice(0, regionReferences.length - maxAnnotationReferences);
        hoveredSelectionIndex = null;
      }
      colorSequence += 1;
      pendingAnnotation = null;
      annotationPhase = "captured";
      // cmux-next has no draw-mode control: the next click picks an element again.
      interactionMode = "select";
      if (overlay) {
        overlay.strokeSvg.style.display = "none";
        overlay.strokePath.setAttribute("points", "");
      }
      revision += 1;
      // Native capture completion is the authoritative phase transition.
      // Reconcile it directly so a frame request paused during WebKit's
      // snapshot cannot strand the outline behind an outstanding frame token.
      refreshOverlay();
      return emit();
    },

    cancelAnnotationCapture(id) {
      if (pendingAnnotation?.id !== String(id || "")) return snapshot();
      resetPendingAnnotation(false);
      return snapshot();
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
      captureSelectionValid = true;
      // Restore synchronously. Native keeps a visual shield above the webview
      // until an after-screen-updates snapshot confirms this state has painted.
      refreshOverlay();
      document.documentElement.getBoundingClientRect();
      return snapshot();
    },
  };

  globalThis.__cmuxDesignMode = api;
})();
