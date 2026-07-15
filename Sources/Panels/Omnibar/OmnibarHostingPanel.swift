import AppKit
import Combine
import Foundation

/// A browser-engine-neutral surface that can host cmux's shared omnibar chrome.
@MainActor
protocol OmnibarHostingPanel: AnyObject, ObservableObject {
    var id: UUID { get }
    var workspaceId: UUID { get }
    var omnibarDisplayURL: URL? { get }
    var pageTitle: String { get }
    var isLoading: Bool { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    var isOmnibarVisible: Bool { get }
    func navigateSmart(_ input: String)
    func resolveNavigableURL(from input: String) -> URL?
    func goBack()
    func goForward()
    func reload()
    func stopLoading()
    func preferredURLStringForOmnibar() -> String?
    var historyStore: BrowserHistoryStore { get }
    var pendingAddressBarFocusRequestId: UUID? { get }
    var pendingAddressBarFocusSelectionIntent: BrowserAddressBarFocusSelectionIntent { get }
    func acknowledgeAddressBarFocusRequest(_ id: UUID)
    @discardableResult
    func requestAddressBarFocus(selectionIntent: BrowserAddressBarFocusSelectionIntent) -> UUID
    func beginSuppressContentFocusForAddressBar()
    func endSuppressContentFocusForAddressBar()
    func shouldSuppressContentFocus() -> Bool
    func shouldSuppressOmnibarAutofocus() -> Bool
    func noteAddressBarFocused()
    var isContentBlankForOmnibar: Bool { get }
    var isContentNavigationInFlight: Bool { get }
    func performAddressBarExitFocusHandoff(
        isCurrentOwner: @escaping @MainActor () -> Bool,
        onComplete: @escaping @MainActor (Bool) -> Void
    )
    var omnibarHostWindow: NSWindow? { get }
}

extension OmnibarHostingPanel {
    func isCurrentOmnibarFocusOwner() -> Bool {
        guard let app = AppDelegate.shared else { return false }
        return omnibarFocusOwnerMatches(
            panelId: id,
            focusedPanel: app.shortcutFocusedOmnibarPanel(in: omnibarHostWindow)
        )
    }
}
