import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation

extension FakeChromiumPage {
    /// The raw `Runtime.bindingCalled` event the page script sends for `payload`.
    static func bindingCall(_ payload: [String: Any], context: Int = 9) -> String {
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let event: [String: Any] = ["method": "Runtime.bindingCalled",
                                    "params": ["name": ChromiumPageHostBridge.bindingName, "payload": text, "executionContextId": context]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self)
    }
}
