import CmuxNextCompat
import Foundation

/// Design mode's messages in a Chromium page (`BrowserDesignModeScript`), through the DevTools
/// protocol like `CEFVerificationBridge`: the runtime runs in cmux's isolated world (`cmux`, where
/// `.isolated` scripts run) and posts through that world's `cmuxDesignModePost` binding; the call
/// arrives as a `Runtime.bindingCalled` event (`CEFAgentRelay.deliver` hands it here) and the tab
/// emits `.designMode`. Nothing is added until the user turns design mode on (``prepare()``), so an
/// idle tab pays nothing.
final class CEFDesignModeBridge {
    /// The isolated world `CEFTab.evaluate(_:world: .isolated, gesture:)` creates.
    static let world = "cmux"

    /// Weak: the tab owns the relay that owns this bridge.
    private weak var tab: CEFTab?

    init(tab: CEFTab) { self.tab = tab }

    /// Readies the main frame's isolated world to post: the world exists (a binding reaches only
    /// worlds that exist when it is added), the binding is in it, and protocol events flow.
    func prepare() async throws {
        guard let tab, let browser = tab.browserID else { throw BrowserTabError.closed }
        tab.agentRelay.designModeListens = true
        // `CEFTab.runtime` is `unowned`, so it is read before the evaluate below, while it is known
        // alive: reading it after that await would trap once the runtime's last owner went, which
        // aborts the process rather than failing this call (see `CEFMediaBridge.run`).
        let runtime = tab.runtime
        _ = try await tab.evaluate("true", world: .isolated, gesture: .cmux)
        _ = try await runtime.devTools(browser, method: "Runtime.addBinding",
                                       params: ["name": BrowserDesignModeScript.chromiumBinding, "executionContextName": Self.world])
    }

    /// A `Runtime.bindingCalled` of the design mode binding: emits its JSON payload. False for
    /// every other message.
    func handle(_ head: DevToolsMessageHead) -> Bool {
        let binding = BrowserDesignModeScript.chromiumBinding
        guard head.method == "Runtime.bindingCalled", head.contains("\"\(binding)\""),
              let data = head.json.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              message["method"] as? String == "Runtime.bindingCalled",
              let params = message["params"] as? [String: Any], params["name"] as? String == binding
        else { return false }
        if let payload = params["payload"] as? String { tab?.emit(.designMode(Data(payload.utf8))) }
        return true
    }
}
