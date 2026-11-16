public import CmuxNextSettings

/// The `browser.page.*` ops of apps: the app's own page service (`BrowserPageService`, the
/// methods `cmux browser tab_… <verb>` runs) on a browser tab this app draws, named by `tab`
/// or, without one, the focused tab. The daemon has no CDP session for such a tab, so this is
/// how an extension reaches its page. The supervisor checked the scope (`browser:execute` for
/// `eval`, `browser:read` for `state`, `browser:write` for the rest) before it routed the call
/// here. Only the params each op documents pass: an app never names an agent's lease or a caller.
public nonisolated struct BrowserPageAppOps: AppHostCapabilityHandler {
    let control: @Sendable (_ method: String, _ params: [String: JSONValue], _ callerApp: String) async throws(AppHostCapabilityError) -> JSONValue

    /// - Parameter control: Runs one control method in process for the calling app.
    public init(control: @escaping @Sendable (_ method: String, _ params: [String: JSONValue], _ callerApp: String) async throws(AppHostCapabilityError) -> JSONValue) {
        self.control = control
    }

    /// Each op and the params it takes besides `tab`.
    static let ops: [String: [String]] = [
        "browser.page.eval": ["script"], "browser.page.state": [], "browser.page.back": [], "browser.page.forward": [],
        "browser.page.reload": [], "browser.page.navigate": ["url"], "browser.page.new_tab": ["url"],
    ]

    public var families: Set<String> { ["browser.page"] }

    public func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
        guard let keys = Self.ops[request.op] else { throw .unsupported(request.op) }
        var params: [String: JSONValue] = [:]
        for key in keys + ["tab"] {
            if let value = request.params[key]?.stringValue { params[key] = .string(value) }
        }
        params["idempotency_key"] = request.idempotencyKey.map(JSONValue.string)
        return AppJSON(try await control(request.op, params, request.app))
    }
}
