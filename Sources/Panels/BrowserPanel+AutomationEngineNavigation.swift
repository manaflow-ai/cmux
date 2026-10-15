import CmuxBrowser
import Foundation
import WebKit

/// Socket automation navigations (`browser navigate`, `reload`, `state load`)
/// on a panel whose page is not WebKit. The load has no `WKNavigation`, so
/// the automation transaction is tied to the engine page's own commit and
/// failure events instead of reading as "not started".
extension BrowserPanel {
    /// Associates an automation navigation with the load just started.
    /// WebKit loads are identified by their `WKNavigation`; an engine page's
    /// load (nil navigation) by the ticket itself.
    func noteAutomationNavigationStarted(
        _ ticket: BrowserAutomationNavigationTicket,
        navigation: WKNavigation?
    ) {
        if navigation == nil, enginePage != nil {
            automationNavigationCoordinator.didStartEngineNavigation(ticket)
            return
        }
        automationNavigationCoordinator.didStart(
            ticket,
            navigationID: navigation.map { ObjectIdentifier($0) }
        )
    }

    /// Finishes a waiting automation navigation from the engine page's events.
    func noteEnginePageAutomationNavigation(_ event: BrowserPageEvent) {
        switch event {
        // Chromium reports a finished load and may not report the commit
        // separately; whichever comes first finishes the transaction.
        case .navigationCommitted, .navigationFinished:
            automationNavigationCoordinator.didCommitEngineNavigation(instanceID: webViewInstanceID)
        case .navigationFailed(_, _, let message, _):
            automationNavigationCoordinator.didFailEngineNavigation(instanceID: webViewInstanceID, message: message)
        default:
            break
        }
    }
}
