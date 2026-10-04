import AppKit
import WebKit

/// Tells whether the one write a REPL Copy or Cut saw on its pasteboard is
/// the commanded page's own.
///
/// WebKit's pasteboard requests do not say which web view they serve, so a
/// copy another web view makes while the command runs lands on the tab's
/// pasteboard too. The redirect counts writes: WebKit's own Copy or Cut
/// writes at most once. But it can write none (the page's handler cancels
/// the event and sets no data, a Cut of text the page cannot edit, a
/// password field), and then another web view's copy is the one write.
///
/// So before the command a listener goes into every frame of the tab, in a
/// content world of its own that neither page nor agent script reaches. On
/// the trusted `copy` or `cut` event it records whether WebKit's default
/// action would write the selection, and puts a random marker type on the
/// event's `clipboardData`: when the page cancels the event, WebKit writes
/// that data, marker included, so the write is the page's own exactly when
/// the marker is on the pasteboard. After the command the event says
/// whether it was cancelled. A write the tab cannot be shown to have made
/// itself (no listener saw the event, the page cleared the marker, the
/// default action wrote nothing) makes the command `interfered`.
///
/// The page sees the marker type among `clipboardData.types` in its own
/// handler, and when it cancels, the marker (a random value used once) is on
/// the tab's clipboard among WebKit's custom data.
@MainActor
struct BrowserReplCopyProbe {
    /// The marker's type on the event's `clipboardData`.
    static let markerType = "application/x-cmux-repl-command"
    private static let world = WKContentWorld.world(name: "cmux-repl-copy-probe")

    private let webView: WKWebView
    private let frames: [WKFrameInfo?]
    private let nonce: String

    /// Puts the listener into every frame of `webView`. A frame that does not
    /// answer has none, and an event there counts as unseen.
    static func arm(in webView: WKWebView) async -> BrowserReplCopyProbe {
        let tree = await BrowserReplFrame.readTree(of: webView)
        let frames: [WKFrameInfo?] = tree.isEmpty ? [nil] : tree.map(\.info)
        let probe = BrowserReplCopyProbe(webView: webView, frames: frames, nonce: UUID().uuidString)
        for frame in frames {
            _ = try? await webView.browserReplCallAsyncJavaScript(
                armSource,
                arguments: ["nonce": probe.nonce, "type": markerType],
                in: frame,
                contentWorld: world,
                userGesture: false
            )
        }
        return probe
    }

    /// Whether `writes` changes of `pasteboard` during the command are all
    /// the commanded page's own. Removes the listeners.
    func accepts(writes: Int, on pasteboard: NSPasteboard) async -> Bool {
        var seen: [[String: Any]] = []
        for frame in frames {
            let value = try? await webView.browserReplCallAsyncJavaScript(
                Self.readSource,
                arguments: ["nonce": nonce],
                in: frame,
                contentWorld: Self.world,
                userGesture: false
            )
            if let record = value as? [String: Any], (record["fired"] as? NSNumber)?.intValue ?? 0 > 0 {
                seen.append(record)
            }
        }
        if writes == 0 { return true }
        guard writes == 1, seen.count == 1, let record = seen.first,
              (record["fired"] as? NSNumber)?.intValue == 1 else { return false }
        if record["canceled"] as? Bool == true { return Self.holdsMarker(nonce, pasteboard) }
        return record["writesSelection"] as? Bool == true
    }

    /// Whether any type on `pasteboard` carries `nonce` (WebKit keeps a
    /// page's custom types in one data blob, its strings in Latin-1 or UTF-16).
    private static func holdsMarker(_ nonce: String, _ pasteboard: NSPasteboard) -> Bool {
        let encodings = [Data(nonce.utf8), nonce.data(using: .utf16LittleEndian) ?? Data()]
        for type in pasteboard.types ?? [] {
            guard let data = pasteboard.data(forType: type) else { continue }
            if encodings.contains(where: { !$0.isEmpty && data.range(of: $0) != nil }) { return true }
        }
        return false
    }

    private static let armSource = """
    const previous = globalThis.__cmuxCopyProbe;
    if (previous) previous.remove();
    const state = { nonce, fired: 0, event: null, writesSelection: false };
    const deepFocus = () => {
      let el = document.activeElement;
      while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
      return el;
    };
    const listener = (e) => {
      if (!e.isTrusted) return;
      state.fired += 1;
      if (state.event) return;
      state.event = e;
      const el = deepFocus();
      let selected = false;
      let editable = false;
      if (el && (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) && el.selectionStart !== null) {
        selected = el.selectionEnd > el.selectionStart && !(el instanceof HTMLInputElement && el.type === "password");
        editable = !el.readOnly && !el.disabled;
      } else {
        const selection = getSelection();
        selected = !!selection && !selection.isCollapsed;
        const node = selection && selection.anchorNode;
        const element = node && (node.nodeType === 1 ? node : node.parentElement);
        editable = document.designMode === "on" || !!(element && element.isContentEditable);
      }
      state.writesSelection = selected && (e.type === "copy" || editable);
      try { if (e.clipboardData) e.clipboardData.setData(type, nonce); } catch (_) {}
    };
    state.remove = () => {
      removeEventListener("copy", listener, true);
      removeEventListener("cut", listener, true);
    };
    addEventListener("copy", listener, true);
    addEventListener("cut", listener, true);
    globalThis.__cmuxCopyProbe = state;
    return true;
    """

    private static let readSource = """
    const state = globalThis.__cmuxCopyProbe;
    if (!state || state.nonce !== nonce) return null;
    state.remove();
    delete globalThis.__cmuxCopyProbe;
    if (!state.event) return { fired: 0 };
    return { fired: state.fired, canceled: state.event.defaultPrevented, writesSelection: state.writesSelection };
    """
}
