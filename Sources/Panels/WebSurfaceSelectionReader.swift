import Foundation
import WebKit

/// Reads DOM or editable-control selection without changing focus or page state.
@MainActor
final class WebSurfaceSelectionReader {
    private let evaluationOwner = WebSurfaceSelectionEvaluationOwner()

    private nonisolated struct Payload: Decodable {
        let hasSelection: Bool
        let text: String

        enum CodingKeys: String, CodingKey {
            case hasSelection = "has_selection"
            case text
        }
    }

    private static let trackingBootstrapScript = """
    (() => {
      const runtimeKey = '__cmuxSurfaceSelectionRuntime';
      // A pre-existing page-owned value is never trusted. The first
      // at-document-start install wins; subsequent installs fail closed.
      if (Object.prototype.hasOwnProperty.call(globalThis, runtimeKey)) return false;

      const maxTextCharacters = \(SurfaceSelectionSnapshot.maximumTextBytes / 4);
      const maxTraversalNodes = 4096;
      const unicodeSafeEnd = (value, offset) => {
        let end = Math.max(0, Math.min(value.length, offset));
        if (end > 0 && end < value.length) {
          const previous = value.charCodeAt(end - 1);
          const next = value.charCodeAt(end);
          if (previous >= 0xD800 && previous <= 0xDBFF &&
              next >= 0xDC00 && next <= 0xDFFF) {
            end -= 1;
          }
        }
        return end;
      };
      const boundedText = (text) => {
        const value = String(text || '');
        if (value.length <= maxTextCharacters) return value;
        return value.slice(0, unicodeSafeEnd(value, maxTextCharacters - 1)) + '…';
      };
      const boundedControlText = (value, start, end) => {
        const source = String(value || '');
        const safeStart = Math.max(0, Math.min(source.length, Number(start) || 0));
        const safeEnd = Math.max(safeStart, Math.min(source.length, Number(end) || 0));
        const length = safeEnd - safeStart;
        if (length <= maxTextCharacters) return source.slice(safeStart, safeEnd);
        const boundedEnd = unicodeSafeEnd(source, safeStart + maxTextCharacters - 1);
        return source.slice(safeStart, boundedEnd) + '…';
      };
      // Range#toString materializes the complete DOM selection. Walk text
      // nodes instead and stop after the wire budget, so large selections do
      // not allocate an unbounded string on every selectionchange/read.
      const boundedRangeText = (range) => {
        try {
          const root = range.commonAncestorContainer;
          const ownerDocument = root.ownerDocument || root;
          const walker = ownerDocument.createTreeWalker(root, 4);
          const boundedRange = range.cloneRange();
          let used = 0;
          let visitedNodes = 0;
          let truncated = false;
          let node = root.nodeType === 3 ? root : walker.nextNode();
          while (node) {
            if (++visitedNodes > maxTraversalNodes) return null;
            const value = node.nodeValue || '';
            let start = 0;
            let end = value.length;
            if (range.comparePoint(node, end) < 0) {
              node = walker.nextNode();
              continue;
            }
            if (range.comparePoint(node, 0) > 0) break;
            if (node === range.startContainer) {
              start = Math.max(0, Math.min(end, range.startOffset));
            }
            if (node === range.endContainer) {
              end = Math.max(start, Math.min(end, range.endOffset));
            }
            if (end > start) {
              // Reserve one character for the visible truncation marker.
              const remaining = maxTextCharacters - 1 - used;
              if (remaining <= 0) {
                boundedRange.setEnd(node, start);
                truncated = true;
                break;
              }
              const count = Math.min(remaining, end - start);
              used += count;
              if (count < end - start) {
                boundedRange.setEnd(node, unicodeSafeEnd(value, start + count));
                truncated = true;
                break;
              }
            }
            if (node === range.endContainer) break;
            node = walker.nextNode();
          }
          const text = boundedText(boundedRange.toString());
          if (!truncated) return text;
          const prefix = text.endsWith('…') ? text.slice(0, -1) : text;
          return boundedText(prefix + '…');
        } catch (_) {
          return null;
        }
      };
      const empty = () => Object.freeze({ has_selection: false, text: '' });
      const unreadable = () => Object.freeze({
        has_selection: false,
        text: '',
        blocks_fallback: true
      });
      const selected = (text, sourceDocument = null, metadata = {}) => Object.freeze({
        has_selection: true,
        text: boundedText(text),
        source_document: sourceDocument,
        ...metadata
      });
      let installDocument;
      const deepestActiveElement = (targetDocument) => {
        let active = targetDocument.activeElement;
        while (active?.shadowRoot?.activeElement) {
          active = active.shadowRoot.activeElement;
        }
        return active;
      };
      const readLiveSelection = (targetWindow) => {
        let targetDocument;
        try {
          targetDocument = targetWindow.document;
        } catch (_) {
          return unreadable();
        }

        const active = deepestActiveElement(targetDocument);
        const activeTag = String(active?.tagName || '').toLowerCase();
        if (activeTag === 'iframe' || activeTag === 'frame') {
          try {
            const childWindow = active.contentWindow;
            if (!childWindow) return unreadable();
            try {
              installDocument?.(childWindow.document);
            } catch (_) {}
            return readLiveSelection(childWindow);
          } catch (_) {
            return unreadable();
          }
        }

        const isInput = activeTag === 'input';
        const isTextControl = isInput || activeTag === 'textarea';
        const isPassword = isInput && String(active.type || '').toLowerCase() === 'password';
        if (isPassword) return unreadable();
        if (isTextControl) {
          if (typeof active.selectionStart === 'number' &&
              typeof active.selectionEnd === 'number' &&
              active.selectionEnd > active.selectionStart) {
            return selected(
              boundedControlText(active.value, active.selectionStart, active.selectionEnd),
              targetDocument,
              {
                selection_control: active,
                selection_start: active.selectionStart,
                selection_end: active.selectionEnd
              }
            );
          }
          return empty();
        }

        const selection = targetWindow.getSelection();
        if (selection && selection.rangeCount > 0 && !selection.isCollapsed) {
          try {
            const range = selection.getRangeAt(0).cloneRange();
            const text = boundedRangeText(range);
            return text === null
              ? unreadable()
              : selected(text, targetDocument, { selection_range: range });
          } catch (_) {
            return unreadable();
          }
        }
        return empty();
      };

      const locationForDocument = (sourceDocument) => {
        try {
          const href = sourceDocument?.location?.href;
          return typeof href === 'string' && href.length > 0 ? href : null;
        } catch (_) {
          return null;
        }
      };
      let retainedSelection = empty();
      let retainedDocument = null;
      let retainedLocation = null;
      let retainedRange = null;
      let retainedControl = null;
      let retainedControlStart = null;
      let retainedControlEnd = null;
      const clear = (sourceDocument = null) => {
        if (sourceDocument && retainedDocument !== sourceDocument) return;
        retainedSelection = empty();
        retainedDocument = null;
        retainedLocation = null;
        retainedRange = null;
        retainedControl = null;
        retainedControlStart = null;
        retainedControlEnd = null;
      };
      const retain = (live) => {
        retainedSelection = selected(live.text);
        retainedDocument = live.source_document || null;
        retainedLocation = locationForDocument(retainedDocument);
        retainedRange = live.selection_range || null;
        retainedControl = live.selection_control || null;
        retainedControlStart = live.selection_start ?? null;
        retainedControlEnd = live.selection_end ?? null;
      };
      const capture = (targetWindow, clearWhenEmpty = false) => {
        const live = readLiveSelection(targetWindow);
        if (live.blocks_fallback) {
          clear();
        } else if (live.has_selection) {
          retain(live);
        } else if (clearWhenEmpty) {
          clear();
        }
      };
      // Socket reads are observers. Re-querying WebKit here would create a
      // second mutation path that can erase the event-owned snapshot after
      // native focus moves to a neighboring surface.
      const retainedContentStillValid = () => {
        if (retainedRange) {
          try {
            if (retainedRange.startContainer?.isConnected === false ||
                retainedRange.endContainer?.isConnected === false) {
              return false;
            }
            const text = boundedRangeText(retainedRange);
            return text !== null && text === retainedSelection.text;
          } catch (_) {
            return false;
          }
        }
        if (retainedControl) {
          try {
            if (retainedControl.isConnected === false) return false;
            const start = Number(retainedControlStart);
            const end = Number(retainedControlEnd);
            return boundedControlText(retainedControl.value, start, end) === retainedSelection.text;
          } catch (_) {
            return false;
          }
        }
        return true;
      };
      const clearIfDetachedFrame = () => {
        if (!retainedDocument || retainedDocument === document) return;
        try {
          const frame = retainedDocument.defaultView?.frameElement;
          if (!frame || !frame.isConnected) clear();
        } catch (_) {
          clear();
        }
      };

      const read = () => {
        clearIfDetachedFrame();
        if (retainedDocument && !retainedContentStillValid()) {
          clear(retainedDocument);
        }
        if (retainedDocument && retainedLocation !== null) {
          const currentLocation = locationForDocument(retainedDocument);
          if (currentLocation !== null && currentLocation !== retainedLocation) {
            clear(retainedDocument);
          }
        }
        return retainedSelection;
      };

      const trackedDocuments = new WeakSet();
      const selectionChangingKeys = new Set([
        'ArrowDown', 'ArrowLeft', 'ArrowRight', 'ArrowUp',
        'Backspace', 'Delete', 'End', 'Enter', 'Escape',
        'Home', 'PageDown', 'PageUp', 'Tab'
      ]);
      const keyChangesSelection = (event) => {
        const key = String(event?.key || '');
        if (selectionChangingKeys.has(key)) return true;
        return key.length === 1 && !event?.metaKey && !event?.ctrlKey;
      };
      const installFrame = (frame) => {
        try {
          if (frame?.contentDocument) installDocument(frame.contentDocument);
        } catch (_) {}
      };
      const scanFrames = (root) => {
        try {
          const rootTag = String(root?.tagName || '').toLowerCase();
          if (rootTag === 'iframe' || rootTag === 'frame') installFrame(root);
          const frames = root?.querySelectorAll?.('iframe, frame') || [];
          for (const frame of frames) installFrame(frame);
        } catch (_) {}
      };
      installDocument = (targetDocument) => {
        if (!targetDocument || trackedDocuments.has(targetDocument)) return;
        trackedDocuments.add(targetDocument);
        let captureQueued = false;
        const captureDocument = () => {
          if (captureQueued) return;
          captureQueued = true;
          queueMicrotask(() => {
            captureQueued = false;
            const targetWindow = targetDocument.defaultView;
            if (!targetWindow) return;
            // A collapsed selectionchange while the document is unfocused is
            // WebKit's native-focus handoff signal. When the page still owns
            // focus, an empty range is an intentional page-side clear.
            capture(targetWindow, targetDocument.hasFocus());
          });
        };
        const clearForInteraction = () => clear();
        // A collapsed selectionchange is not itself a clear signal: WebKit
        // also emits one when native focus moves to a neighboring surface.
        // Concrete page interaction owns clearing; a later non-empty change
        // replaces the retained immutable snapshot.
        targetDocument.addEventListener('selectionchange', captureDocument, true);
        targetDocument.addEventListener('select', captureDocument, true);
        targetDocument.addEventListener('selectstart', clearForInteraction, true);
        targetDocument.addEventListener('pointerdown', clearForInteraction, true);
        targetDocument.addEventListener('mousedown', clearForInteraction, true);
        targetDocument.addEventListener('keydown', (event) => {
          if (keyChangesSelection(event)) clear();
        }, true);
        targetDocument.addEventListener('focusin', captureDocument, true);
        targetDocument.addEventListener('input', captureDocument, true);
        const invalidateForNavigation = () => clear(targetDocument);
        targetDocument.defaultView?.addEventListener('hashchange', invalidateForNavigation, true);
        targetDocument.defaultView?.addEventListener('popstate', invalidateForNavigation, true);
        targetDocument.defaultView?.addEventListener('pagehide', invalidateForNavigation, true);
        targetDocument.addEventListener('load', (event) => {
          const target = event?.target;
          const tag = String(target?.tagName || '').toLowerCase();
          if (tag === 'iframe' || tag === 'frame') {
            installFrame(target);
            captureDocument();
          }
        }, true);
        targetDocument.addEventListener('DOMContentLoaded', () => {
          scanFrames(targetDocument);
          captureDocument();
        }, { once: true });
        // The initial scan and capture-phase load listener discover frames at
        // their lifecycle boundary. Selection reads validate retained ranges
        // lazily, so a document-wide mutation observer is unnecessary work.
        scanFrames(targetDocument);
        const targetWindow = targetDocument.defaultView;
        targetWindow?.addEventListener('beforeunload', () => {
          if (targetDocument === document) {
            clear();
          } else {
            clear(targetDocument);
          }
        }, true);
      };

      // Keep the page-world bridge immutable. Site JavaScript shares this
      // world, so a writable global would let a page replace `read` and
      // bypass the password-control guard before the app evaluates it.
      const runtime = Object.freeze({ read });
      Object.defineProperty(globalThis, runtimeKey, {
        configurable: false,
        enumerable: false,
        value: runtime,
        writable: false
      });
      installDocument(document);
      capture(window);
      return true;
    })()
    """

    private static let evaluationTimeoutMilliseconds = 4_000
    private static let script = """
    (async () => {
      const readSelection = () => {
        const runtime = globalThis.__cmuxSurfaceSelectionRuntime;
        if (!runtime || typeof runtime.read !== 'function') return null;
        const maxTextCharacters = \(SurfaceSelectionSnapshot.maximumTextBytes / 4);
        const unicodeSafeEnd = (value, offset) => {
          let end = Math.max(0, Math.min(value.length, offset));
          if (end > 0 && end < value.length) {
            const previous = value.charCodeAt(end - 1);
            const next = value.charCodeAt(end);
            if (previous >= 0xD800 && previous <= 0xDBFF &&
                next >= 0xDC00 && next <= 0xDFFF) {
              end -= 1;
            }
          }
          return end;
        };
        const boundedText = (text) => {
          const value = String(text || '');
          if (value.length <= maxTextCharacters) return value;
          return value.slice(0, unicodeSafeEnd(value, maxTextCharacters - 1)) + '…';
        };
        const result = runtime.read();
        return JSON.stringify({
          has_selection: result?.has_selection === true,
          text: result?.has_selection === true ? boundedText(result.text) : ''
        });
      };
      return await Promise.race([
        Promise.resolve().then(readSelection),
        new Promise((resolve) => setTimeout(() => resolve(null), \(WebSurfaceSelectionReader.evaluationTimeoutMilliseconds)))
      ]);
    })()
    """

    /// Installs the event-owned snapshot in the page world because WebKit does
    /// not project its live `Selection` object into isolated content worlds.
    @MainActor
    static func installTracking(in userContentController: WKUserContentController) {
        userContentController.addUserScript(WKUserScript(
            source: trackingBootstrapScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        ))
    }

    @MainActor
    func read(
        webView: WKWebView,
        kind: PanelType,
        filePath: String? = nil,
        url: String? = nil
    ) async -> SurfaceSelectionReadResult {
        guard let encoded = await evaluationOwner.evaluate(
            webView: webView,
            script: Self.script
        ), let data = encoded.data(using: .utf8) else {
            return .unavailable
        }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            let normalizedPath = filePath.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            }
            if payload.hasSelection {
                return .snapshot(.selected(
                    kind: kind,
                    text: SurfaceSelectionSnapshot.boundedText(payload.text),
                    filePath: normalizedPath,
                    url: url
                ))
            }
            return .snapshot(.none(
                kind: kind,
                filePath: normalizedPath,
                url: url
            ))
        } catch {
            return .unavailable
        }
    }
}
