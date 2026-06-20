public import AppKit

/// Presents the success/failure ``AppKit/NSAlert`` for the cmux CLI `PATH` install and uninstall
/// actions surfaced from the update menu.
///
/// This lifts the app target's former `presentCLIPathAlert(title:informativeText:style:)` into the
/// updater UI package: the host builds the already-localized title and body (the localization
/// catalog lives in the app target), and this presenter owns the AppKit assembly and presentation.
/// It is a real instance over an injected key-window provider, so the app target constructs one and
/// supplies the live `NSApp.keyWindow ?? NSApp.mainWindow` resolver, while tests inject a fake
/// window provider to exercise the sheet-versus-modal branch without a running app.
@MainActor
public struct CmuxCLIPathAlertPresenter {
    /// Resolves the window the alert should attach to as a sheet, or `nil` to run it as a modal.
    public typealias AnchorWindowProvider = () -> NSWindow?

    private let anchorWindowProvider: AnchorWindowProvider
    private let okButtonTitle: String

    /// Creates a presenter over the given anchor-window resolver and OK-button title.
    ///
    /// - Parameters:
    ///   - anchorWindowProvider: Returns the window the alert sheets onto; when it returns `nil`
    ///     the alert runs as an application-modal dialog. The host passes the live
    ///     `NSApp.keyWindow ?? NSApp.mainWindow` resolver.
    ///   - okButtonTitle: The localized "OK" button label, supplied by the host so the catalog stays
    ///     in the app target.
    public init(
        anchorWindowProvider: @escaping AnchorWindowProvider,
        okButtonTitle: String
    ) {
        self.anchorWindowProvider = anchorWindowProvider
        self.okButtonTitle = okButtonTitle
    }

    /// Presents the alert with the given already-localized title and body. Sheets onto the resolved
    /// anchor window when one exists, otherwise runs application-modal.
    public func present(
        title: String,
        informativeText: String,
        style: NSAlert.Style
    ) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = informativeText
        alert.addButton(withTitle: okButtonTitle)

        if let window = anchorWindowProvider() {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            _ = alert.runModal()
        }
    }
}
