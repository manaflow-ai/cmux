import Foundation

extension BrowserControlService {
    /// Builds an atomic file-input assignment using standard DOM file APIs.
    /// - Parameters:
    ///   - selectorLiteral: A JSON-encoded CSS selector, including its quotes.
    ///   - filesJSON: The trusted payload from ``BrowserInputFileService``.
    /// - Returns: An expression compatible with the browser selector-action path.
    public func inputFilesScript(selectorLiteral: String, filesJSON: String) -> String {
        let invalidTarget = jsonLiteral(String(
            localized: "browser.inputFiles.error.invalidTarget",
            defaultValue: "The selector must match a file input without directory selection"
        ))
        let multipleRequired = jsonLiteral(String(
            localized: "browser.inputFiles.error.multipleRequired",
            defaultValue: "This file input does not allow multiple files"
        ))
        return """
        (() => {
          const el = document.querySelector(\(selectorLiteral));
          if (!el) return { ok: false, error: 'not_found' };
          if (el.tagName !== 'INPUT' || el.type !== 'file' || el.webkitdirectory) {
            throw new Error(\(invalidTarget));
          }
          const files = \(filesJSON);
          if (!el.multiple && files.length > 1) throw new Error(\(multipleRequired));
          // Use the input's realm, including when an iframe is selected.
          const view = el.ownerDocument.defaultView;
          const transfer = new view.DataTransfer();
          for (const file of files) {
            const binary = view.atob(file.base64);
            const bytes = new view.Uint8Array(binary.length);
            for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
            transfer.items.add(new view.File([bytes], file.name, {
              type: file.type, lastModified: file.lastModified
            }));
          }
          el.files = transfer.files;
          el.dispatchEvent(new view.Event('input', { bubbles: true, composed: true }));
          el.dispatchEvent(new view.Event('change', { bubbles: true }));
          return { ok: true, value: { count: el.files.length } };
        })()
        """
    }
}
