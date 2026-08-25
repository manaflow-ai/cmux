import Foundation
import WebKit

/// Reads DOM or editable-control selection without changing focus or page state.
nonisolated struct WebSurfaceSelectionReader {
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
      if (globalThis.__cmuxSurfaceSelectionRuntime) return true;

      const maxTextCharacters = \(SurfaceSelectionSnapshot.maximumTextBytes / 4);
      const boundedText = (text) => {
        const value = String(text || '');
        if (value.length <= maxTextCharacters) return value;
        return value.slice(0, maxTextCharacters - 1) + '…';
      };
      const empty = () => ({ has_selection: false, text: '' });
      const unreadable = () => ({ has_selection: false, text: '', blocks_fallback: true });
      const selected = (text, sourceDocument = null, metadata = {}) => ({
        has_selection: true,
        text: boundedText(text),
        source_document: sourceDocument,
        ...metadata
      });
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
            return childWindow ? readLiveSelection(childWindow) : unreadable();
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
              String(active.value || '').slice(active.selectionStart, active.selectionEnd),
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
            return selected(selection.toString(), targetDocument, {
              selection_range: selection.getRangeAt(0).cloneRange()
            });
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
            return boundedText(retainedRange.toString()) === retainedSelection.text;
          } catch (_) {
            return false;
          }
        }
        if (retainedControl) {
          try {
            if (retainedControl.isConnected === false) return false;
            const start = Number(retainedControlStart);
            const end = Number(retainedControlEnd);
            return boundedText(String(retainedControl.value || '').slice(start, end)) === retainedSelection.text;
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
      let installDocument;
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
        const captureDocument = () => {
          const targetWindow = targetDocument.defaultView;
          if (targetWindow) capture(targetWindow);
        };
        const reconcileInput = () => {
          const targetWindow = targetDocument.defaultView;
          if (targetWindow) capture(targetWindow, true);
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
        targetDocument.addEventListener('input', reconcileInput, true);
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
      Object.defineProperty(globalThis, '__cmuxSurfaceSelectionRuntime', {
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

    private static let script = """
    (() => {
      const runtime = globalThis.__cmuxSurfaceSelectionRuntime;
      if (!runtime || typeof runtime.read !== 'function') return null;
      const maxTextCharacters = \(SurfaceSelectionSnapshot.maximumTextBytes / 4);
      const boundedText = (text) => {
        const value = String(text || '');
        if (value.length <= maxTextCharacters) return value;
        return value.slice(0, maxTextCharacters - 1) + '…';
      };
      const result = runtime.read();
      return JSON.stringify({
        has_selection: result?.has_selection === true,
        text: result?.has_selection === true ? boundedText(result.text) : ''
      });
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
        do {
            guard let encoded = try await webView.evaluateJavaScript(
                Self.script,
                contentWorld: .page
            ) as? String,
            let data = encoded.data(using: .utf8) else {
                return .unavailable
            }
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
        } catch is CancellationError {
            return .unavailable
        } catch {
            return .unavailable
        }
    }
}
