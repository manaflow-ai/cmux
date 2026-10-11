public import Foundation

/// The certificate warning page's controls (`LoadErrorView`: Go Back and
/// Proceed) as registry actions, so the keyboard, the palette and
/// `action.run` take the buttons' path. Enabled only while a WebKit tab
/// shows the warning page; Chromium shows its own interstitial, whose
/// buttons are in the page (Back still works there through browserBack).
public nonisolated enum CertificateWarningCommand: String, CaseIterable, Hashable, Sendable {
    case proceed
    case goBack

    public static let proceedActionID = "browser.certificateWarning.proceed"
    public static let goBackActionID = "browser.certificateWarning.goBack"

    /// The registry action that runs this command.
    public var actionID: String {
        switch self {
        case .proceed: Self.proceedActionID
        case .goBack: Self.goBackActionID
        }
    }

    public init?(actionID: String) {
        guard let command = Self.allCases.first(where: { $0.actionID == actionID }) else { return nil }
        self = command
    }
}

extension CertificateWarningCommand {
    /// Why the command cannot run on `tab` now, or nil.
    @MainActor
    public func unavailableReason(on tab: (any BrowserTab)?) -> String? {
        guard let tab else { return Strings.certificateWarningNotShown }
        // Chromium's interstitial is its own page, not cmux's LoadErrorView.
        guard tab.engineKind == .webkit, tab is any BrowserCertificateBypassing else { return Strings.certificateWarningChromium }
        guard let error = tab.state.loadError, error.isCertificateError, error.failingURL?.host() != nil else {
            return Strings.certificateWarningNotShown
        }
        return nil
    }

    /// Runs the command on `tab`: the warning page's buttons and the
    /// action handlers both call this.
    @MainActor
    public func perform(on tab: any BrowserTab) {
        switch self {
        case .proceed:
            (tab as? any BrowserCertificateBypassing)?.proceedPastCertificateError()
        case .goBack:
            // Nowhere to go back to (the bad page was the first): a blank page.
            if tab.state.canGoBack {
                tab.goBack()
            } else if let blank = URL(string: BrowserNewTabPage.blankURL) {
                tab.load(blank)
            }
        }
    }
}
