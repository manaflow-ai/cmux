import Foundation
import WebKit

/// Forwards sidebar webview action messages without retaining the coordinator.
final class CustomSidebarWebActionMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var coordinator: CustomSidebarWebViewCoordinator?

    init(coordinator: CustomSidebarWebViewCoordinator) {
        self.coordinator = coordinator
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        coordinator?.runAction(messageBody: message.body)
    }
}
