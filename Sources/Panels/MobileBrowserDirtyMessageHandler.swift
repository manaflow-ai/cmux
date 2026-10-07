import Foundation
import WebKit

final class MobileBrowserDirtyMessageHandler: NSObject, WKScriptMessageHandler {
    static let name = "cmuxMobileBrowserStream"

    private let receive: @MainActor (Bool?) -> Void

    init(receive: @escaping @MainActor (Bool?) -> Void) {
        self.receive = receive
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let body = message.body as? [String: Any]
        let editableFocused = body?["editable_focused"] as? Bool
        // WebKit delivers script messages on the main thread. Apply this
        // snapshot synchronously so mobile chrome observes the edit state from
        // this message before handling the next input event.
        MainActor.assumeIsolated {
            receive(editableFocused)
        }
    }
}
