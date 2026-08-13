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
        MainActor.assumeIsolated {
            receive(editableFocused)
        }
    }
}
