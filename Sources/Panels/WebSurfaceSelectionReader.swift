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

    private static let script = """
    (() => {
      const empty = () => ({ has_selection: false, text: '' });
      const readSelection = (targetWindow) => {
        let targetDocument;
        try {
          targetDocument = targetWindow.document;
        } catch (_) {
          return empty();
        }

        const active = targetDocument.activeElement;
        const activeTag = String(active?.tagName || '').toLowerCase();
        if (activeTag === 'iframe' || activeTag === 'frame') {
          try {
            const childWindow = active.contentWindow;
            return childWindow ? readSelection(childWindow) : empty();
          } catch (_) {
            return empty();
          }
        }

        const isInput = activeTag === 'input';
        const isTextControl = isInput || activeTag === 'textarea';
        const isPassword = isInput && String(active.type || '').toLowerCase() === 'password';
        if (isPassword) {
          return empty();
        }
        if (isTextControl &&
            typeof active.selectionStart === 'number' &&
            typeof active.selectionEnd === 'number' &&
            active.selectionEnd > active.selectionStart) {
          return {
            has_selection: true,
            text: String(active.value || '').slice(active.selectionStart, active.selectionEnd)
          };
        }

        const selection = targetWindow.getSelection();
        const hasSelection = !!selection && selection.rangeCount > 0 && !selection.isCollapsed;
        return {
          has_selection: hasSelection,
          text: hasSelection ? selection.toString() : ''
        };
      };

      return JSON.stringify(readSelection(window));
    })()
    """

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
                    text: payload.text,
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
