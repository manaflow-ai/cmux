public import WebKit

extension BrowserReplFrameGate {
    /// An agent's Meta+C, Meta+X or Meta+V in a tab a session created.
    public enum ClipboardShortcut: String, Sendable {
        case copy, cut, paste
    }

    /// Runs `shortcut` on the tab's virtual clipboard, never a pasteboard,
    /// and returns what the tab's clipboard takes (`nil` for a Paste).
    ///
    /// The frame that holds the focus is found by following each document's
    /// focused frame element from the main frame. A script in the gate's own
    /// content world then runs in that frame's document, through
    /// ``callAsyncJavaScript(_:arguments:in:frame:contentWorld:userGesture:)``:
    /// with a domain policy the gate authorizes the document and the script
    /// checks, in the same turn, that it still runs in that document. In that
    /// turn the script dispatches the `copy`, `cut` or `paste` event (a
    /// `ClipboardEvent` with a `DataTransfer`; the page's handlers run, the
    /// event is not trusted) at the focused element and does the default
    /// action unless a handler cancelled it: Copy and Cut take the selection
    /// (Cut deletes it from an editable target), Paste inserts the
    /// clipboard's text. So the tab's clipboard takes only data that
    /// document's event produced, and the paste reaches only the document the
    /// gate checked, wherever the page moves the focus meanwhile. Copy and
    /// Cut with nothing selected leave the clipboard empty without an event.
    ///
    /// - Parameters:
    ///   - clipboard: the tab's clipboard items (`{ type, base64 }`), for a Paste.
    ///   - beforeDelivery: runs after the focused frame is found and before
    ///     the script is sent (tests stand in for the page moving the focus).
    /// - Throws: `blocked` when the focus is in a frame the policy blocks,
    ///   `stale` when the focused frame cannot be told or the focus moved
    ///   into a child frame before the script ran.
    public func runClipboardShortcut(
        _ shortcut: ClipboardShortcut,
        clipboard: [[String: Any]],
        in webView: WKWebView,
        frames: @MainActor () async -> [BrowserReplFrame]
    ) async throws -> [[String: Any]]? {
        try await runClipboardShortcut(shortcut, clipboard: clipboard, in: webView, frames: frames, beforeDelivery: nil)
    }

    func runClipboardShortcut(
        _ shortcut: ClipboardShortcut,
        clipboard: [[String: Any]],
        in webView: WKWebView,
        frames: @MainActor () async -> [BrowserReplFrame],
        beforeDelivery: (@MainActor () async throws -> Void)?
    ) async throws -> [[String: Any]]? {
        let tree = await frames()
        try await checkFocus(in: webView, frames: tree)
        let leaf = try await focusedFrame(in: webView, tree: tree)
        try await beforeDelivery?()
        let value = try await callAsyncJavaScript(
            Self.clipboardShortcutSource,
            arguments: ["kind": shortcut.rawValue, "items": clipboard],
            in: webView,
            frame: leaf,
            contentWorld: world
        )
        let result = value as? [String: Any] ?? [:]
        if result["moved"] as? Bool == true {
            throw BrowserReplDriverError(code: "stale", message: "The focus moved into a child frame before the \(shortcut.rawValue) ran, so it did nothing; try again")
        }
        guard shortcut != .paste else { return nil }
        let pairs = result["items"] as? [Any] ?? []
        let items: [[String: Any]] = pairs.compactMap { entry in
            guard let pair = entry as? [Any], pair.count == 2,
                  let type = pair[0] as? String, let text = pair[1] as? String else { return nil }
            return ["type": type, "base64": Data(text.utf8).base64EncodedString()]
        }
        // Copying nothing leaves an empty clipboard.
        return items.isEmpty ? [["type": "text/plain", "base64": ""]] : items
    }

    /// The frame whose document holds the keyboard focus: from the main
    /// frame, the child whose frame element each document focused.
    private func focusedFrame(in webView: WKWebView, tree: [BrowserReplFrame]) async throws -> BrowserReplFrame {
        let probe = BrowserReplScriptProbe()
        guard var current = tree.first else {
            throw BrowserReplDriverError(code: "stale", message: "The tab has no frames to run the clipboard shortcut in; try again")
        }
        var positions: [String: Int] = [:]
        for _ in 0..<tree.count {
            let answer = try await probe.call(
                Self.focusedChildSource, arguments: [:], in: webView, frame: current.info, contentWorld: world,
                what: "frame \(current.url) did not report its focus"
            ) as? [String: Any] ?? [:]
            guard answer["inner"] as? Bool == true else { return current }
            let index = (answer["index"] as? NSNumber)?.intValue ?? -1
            var next: BrowserReplFrame?
            for child in tree where child.parentFrameID == current.frameID && index >= 0 {
                if positions[child.frameID] == nil {
                    let reported = try? await probe.call(
                        Self.ownPositionSource, arguments: [:], in: webView, frame: child.info, contentWorld: world,
                        what: "frame \(child.url) did not report its position"
                    )
                    positions[child.frameID] = (reported as? NSNumber)?.intValue ?? -1
                }
                if positions[child.frameID] == index {
                    next = child
                    break
                }
            }
            guard let next else {
                throw BrowserReplDriverError(code: "stale", message: "Could not tell which frame inside \(current.url) holds the focus (a frame in a shadow tree, or the frames changed); the clipboard shortcut did nothing")
            }
            current = next
        }
        throw BrowserReplDriverError(code: "stale", message: "The frames changed while the clipboard shortcut looked for the focus; try again")
    }

    /// Whether the document's focused element (inside shadow trees too) is a
    /// frame element, and that frame's position in `window.frames` (-1 when
    /// it is not listed there).
    private static let focusedChildSource = """
    let e = document.activeElement;
    while (e && e.shadowRoot && e.shadowRoot.activeElement) e = e.shadowRoot.activeElement;
    if (!\(frameElementTest("e"))) return { inner: false, index: -1 };
    let index = -1;
    const w = e.contentWindow;
    for (let i = 0; w && i < window.frames.length; i++) if (window.frames[i] === w) { index = i; break; }
    return { inner: true, index };
    """

    /// The frame's own position in its parent's `window.frames`.
    private static let ownPositionSource = """
    const p = window.parent;
    if (p === window) return -1;
    for (let i = 0; i < p.length; i++) if (p[i] === window) return i;
    return -1;
    """

    /// Runs in the focused frame's document, in the gate's world, in one
    /// turn: the event, the page's handlers and the default action.
    private static let clipboardShortcutSource = """
    let el = document.activeElement || document.body || document.documentElement;
    while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
    if (\(frameElementTest("el"))) return { moved: true };
    const target = el || document.documentElement;
    const isField = (node) => (node instanceof HTMLInputElement || node instanceof HTMLTextAreaElement)
      && typeof node.selectionStart === "number";
    const editable = (node) => !!node && (isField(node) ? !node.readOnly && !node.disabled : node.isContentEditable || document.designMode === "on");
    const event = (type, data) => new ClipboardEvent(type, { clipboardData: data, bubbles: true, cancelable: true, composed: true });
    if (kind === "paste") {
      const data = new DataTransfer();
      let text = "";
      for (const item of items) {
        try {
          const type = String(item.type);
          const raw = atob(String(item.base64));
          const bytes = new Uint8Array(raw.length);
          for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
          const mime = type.startsWith("web ") ? type.slice(4) : type;
          if (mime.startsWith("image/")) {
            data.items.add(new File([bytes], "clipboard", { type: mime }));
          } else {
            const value = new TextDecoder().decode(bytes);
            data.setData(mime, value);
            if (mime === "text/plain") text = value;
          }
        } catch {}
      }
      const cancelled = !target.dispatchEvent(event("paste", data));
      if (!cancelled && text) {
        const now = document.activeElement;
        if (editable(now) || editable(target)) document.execCommand("insertText", false, text);
      }
      return { pasted: !cancelled };
    }
    const selection = () => {
      if (isField(el)) return el.value.slice(el.selectionStart, el.selectionEnd);
      return String(getSelection() || "");
    };
    if (!selection()) return { items: [] };
    const data = new DataTransfer();
    if (!target.dispatchEvent(event(kind, data))) {
      return { items: Array.from(data.types).filter((t) => t !== "Files").map((t) => [t, data.getData(t)]) };
    }
    const text = selection();
    if (!text) return { items: [] };
    const out = [["text/plain", text]];
    if (!isField(el)) {
      const range = getSelection().rangeCount ? getSelection().getRangeAt(0) : null;
      if (range) {
        const holder = document.createElement("div");
        holder.append(range.cloneContents());
        out.push(["text/html", holder.innerHTML]);
      }
    }
    if (kind === "cut" && (editable(el) || editable(target))) document.execCommand("delete");
    return { items: out };
    """
}
