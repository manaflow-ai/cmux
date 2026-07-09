import Foundation

/// JavaScript builders for the browser script-injection and dialog control
/// commands (`browser.addstyle`, `browser.dialog.accept`,
/// `browser.dialog.dismiss`).
///
/// Every string returned here is byte-identical to the script the corresponding
/// `controlBrowser*` witness previously assembled inline in `TerminalController`;
/// only the assembly moved into this package, mirroring the storage and
/// interaction builders elsewhere in this service.
///
/// The owning `@MainActor` controller (app side) still owns the panel
/// resolution, the per-surface init-script/style/dialog-queue state, the
/// `WKUserScript` registration, the WebKit evaluation seam, the dialog-hook
/// bootstrap, and the RPC reply shaping; it forwards into these pure builders for
/// the script text, so the RPC wire output is unchanged.
///
/// `browser.addinitscript` and `browser.addscript` evaluate the caller-supplied
/// script verbatim (no inlined wrapper to drain), so they have no builder here.
extension BrowserControlService {
    /// Builds the `browser.addstyle` document-start `<style>`-injecting script.
    ///
    /// Creates a `<style>` element whose `textContent` is the supplied CSS literal
    /// and appends it to `document.head` (falling back to `documentElement`, then
    /// `body`). The controller registers this as a `WKUserScript` at
    /// `.atDocumentStart` and also evaluates it once for the already-loaded page.
    /// Byte-identical to the script previously inlined in
    /// `controlBrowserAddStyle`.
    /// - Parameter cssLiteral: the already-encoded JavaScript string literal for
    ///   the CSS, as produced by ``jsonLiteral(_:)``.
    /// - Returns: a self-invoking JavaScript expression.
    public func addStyleScript(cssLiteral: String) -> String {
        """
        (() => {
          const el = document.createElement('style');
          el.textContent = String(\(cssLiteral));
          (document.head || document.documentElement || document.body).appendChild(el);
          return true;
        })()
        """
    }

    /// Builds the `browser.dialog.accept` / `browser.dialog.dismiss` page-world
    /// script.
    ///
    /// Shifts the front entry off the in-page dialog queue
    /// (`window.__cmuxDialogQueue`), records the chosen default for a `confirm`
    /// (the accept flag) or a `prompt` (the supplied text when accepting, else
    /// `null`), and returns `{ ok, dialog, remaining }`, or
    /// `{ ok: false, error: 'not_found' }` when the queue is empty. Byte-identical
    /// to the script previously inlined in `controlBrowserDialogRespond`.
    /// - Parameters:
    ///   - acceptLiteral: the JavaScript boolean literal (`"true"` / `"false"`)
    ///     for whether the dialog was accepted.
    ///   - textLiteral: the already-encoded JavaScript value literal for the
    ///     prompt text (`"null"` when no text), as produced by ``jsonLiteral(_:)``.
    /// - Returns: a self-invoking JavaScript expression.
    public func dialogRespondScript(acceptLiteral: String, textLiteral: String) -> String {
        """
        (() => {
          const q = window.__cmuxDialogQueue || [];
          if (!q.length) return { ok: false, error: 'not_found' };
          const entry = q.shift();
          if (entry.type === 'confirm') {
            window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
            window.__cmuxDialogDefaults.confirm = \(acceptLiteral);
          }
          if (entry.type === 'prompt') {
            window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
            if (\(acceptLiteral)) {
              window.__cmuxDialogDefaults.prompt = \(textLiteral);
            } else {
              window.__cmuxDialogDefaults.prompt = null;
            }
          }
          return { ok: true, dialog: entry, remaining: q.length };
        })()
        """
    }
}
