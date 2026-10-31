package import CoreGraphics

/// The page-world script that asks a page whether it uses Command + scroll at a point, and its
/// answer. Owned by `CEFEngine`'s ``PageCommandScrollArbiter`` conformance
/// (`layout.pagesHandleCommandScroll`).
///
/// The script dispatches one cancelable `wheel` event with `metaKey` and zero deltas at the
/// element under the viewport point (CSS pixels), through open shadow roots and into same-origin
/// frames. `dispatchEvent` returns false exactly when a listener called `preventDefault`: Figma
/// and Excalidraw do for a Command wheel (their zoom), ordinary pages do not. The zero deltas
/// zoom and scroll nothing. A frame the page cannot read (another origin) counts as not handling
/// it, so the columns move over it.
package nonisolated struct BrowserCommandScrollProbe: Sendable {
    /// How many frames deep the walk follows.
    package static let maxFrameDepth = 8

    package init() {}

    package func script(x: CGFloat, y: CGFloat) -> String {
        let px = Double(x).isFinite ? Double(x) : 0
        let py = Double(y).isFinite ? Double(y) : 0
        return """
        (() => {
          const probe = (win, x, y, depth) => {
            const doc = win.document;
            let hit = doc.elementFromPoint(x, y);
            while (hit && hit.shadowRoot) {
              const inner = hit.shadowRoot.elementFromPoint(x, y);
              if (!inner || inner === hit) break;
              hit = inner;
            }
            if (!hit) return false;
            if (hit.tagName === 'IFRAME' || hit.tagName === 'FRAME') {
              let inner = null;
              try { inner = hit.contentWindow && hit.contentWindow.document ? hit.contentWindow : null; } catch (error) { inner = null; }
              if (!inner || depth >= \(Self.maxFrameDepth)) return false;
              const rect = hit.getBoundingClientRect();
              return probe(inner, x - rect.left - hit.clientLeft, y - rect.top - hit.clientTop, depth + 1);
            }
            const event = new win.WheelEvent('wheel', {
              bubbles: true, cancelable: true, composed: true, metaKey: true,
              clientX: x, clientY: y, deltaX: 0, deltaY: 0, deltaMode: 0,
            });
            return !hit.dispatchEvent(event);
          };
          try { return probe(window, \(px), \(py), 0); } catch (error) { return false; }
        })()
        """
    }

    /// The script's answer: true when the page cancelled the event; false for anything else.
    package func handles(_ value: BrowserJSValue) -> Bool {
        if case .bool(true) = value { return true }
        return false
    }
}
