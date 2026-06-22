/// A queued in-page JavaScript dialog (`alert`/`confirm`/`prompt`) awaiting a
/// `browser.dialog.accept` / `browser.dialog.dismiss` response, as exposed to the
/// control-plane `browser.dialog.*` witnesses.
///
/// The wire-faithful projection of an entry in
/// ``BrowserAutomationSurfaceState``'s per-surface dialog queue: `index` is the
/// entry's queue position, and `type` / `message` / `defaultText` mirror the
/// captured dialog. The responder closure that resolves the native dialog is
/// retained inside the store and is not surfaced here.
public struct BrowserAutomationDialogDescriptor: Sendable, Equatable {
    /// The entry's zero-based position in the surface's dialog queue.
    public let index: Int

    /// The dialog kind (`"alert"`, `"confirm"`, `"prompt"`, …) captured verbatim.
    public let type: String

    /// The dialog's message text.
    public let message: String

    /// The prompt's default text, when the dialog is a `prompt` with a default.
    public let defaultText: String?

    /// Creates a dialog descriptor.
    public init(index: Int, type: String, message: String, defaultText: String?) {
        self.index = index
        self.type = type
        self.message = message
        self.defaultText = defaultText
    }
}
