public import Foundation

/// JavaScript-backed editing primitives for ``ChromiumEditingCommand``.
///
/// These run in the focused document of the session's first shell window via
/// ``ChromiumSession/executeJavaScript(_:)``. They cover the main frame only;
/// selections inside cross-origin iframes are out of reach until the OWL wire
/// protocol grows native edit-command support.
extension ChromiumSession {
    /// Selects all content in the focused document or text control.
    public func selectAllInFocusedDocument() async throws {
        _ = try await executeJavaScript("document.execCommand('selectAll')")
    }

    /// Returns the focused document's current selection as plain text.
    ///
    /// Reads `selectionStart`/`selectionEnd` for focused text controls (where
    /// `document.getSelection()` does not expose the control's selection) and
    /// falls back to the document selection otherwise.
    public func focusedSelectionText() async throws -> String {
        let script = """
        (() => {
          const el = document.activeElement;
          if (el && typeof el.selectionStart === 'number' && typeof el.value === 'string') {
            return el.value.substring(el.selectionStart, el.selectionEnd);
          }
          return String(document.getSelection());
        })()
        """
        let json = try await executeJavaScript(script)
        return Self.decodeJSONStringFragment(json) ?? ""
    }

    /// Deletes the focused document's current selection.
    public func deleteFocusedSelection() async throws {
        _ = try await executeJavaScript("document.execCommand('delete')")
    }

    /// Inserts plain text at the focused document's insertion point,
    /// replacing the current selection.
    public func insertTextIntoFocusedDocument(_ text: String) async throws {
        let literal = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
        _ = try await executeJavaScript("document.execCommand('insertText', false, \(literal))")
    }

    /// Undoes the last editing operation in the focused document.
    public func undoEditingInFocusedDocument() async throws {
        _ = try await executeJavaScript("document.execCommand('undo')")
    }

    /// Redoes the last undone editing operation in the focused document.
    public func redoEditingInFocusedDocument() async throws {
        _ = try await executeJavaScript("document.execCommand('redo')")
    }

    /// Decodes one JSON-encoded string fragment returned by the shell's
    /// `ExecuteJavaScript`, or `nil` when the result is not a string.
    static func decodeJSONStringFragment(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return value as? String
    }
}
