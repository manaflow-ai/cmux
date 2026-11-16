public import CmuxNextSettings
import Foundation

/// `browser.page.eval {script, tab?}` for apps (`browserPage.eval` in cmux-extension-sdk): runs
/// `script` in the page of a browser tab this app draws, the named tab or else the focused one, and
/// answers `{tab, value}`. It is the control socket's `browser.page.eval` (the App passes its
/// in-process control router), so the tab rule, the JSON-safe wrapper and the errors are the CLI's.
/// The supervisor already checked the app's `browser.page:control` grant, a sensitive scope the
/// person accepts on the consent sheet when they turn the extension on. An app names only `script`
/// and `tab`: it cannot pose as an agent driver.
public nonisolated struct BrowserPageAppOps: AppHostCapabilityHandler {
    /// Runs one control method in process for the calling app.
    let control: @Sendable (_ method: String, _ params: [String: JSONValue], _ callerApp: String) async throws(AppHostCapabilityError) -> JSONValue

    /// The largest script an app may send (the provider channel caps params at 64 KiB).
    public static let maxScript = 60_000

    /// - Parameter control: Runs a control method in process (`ControlRouter.appControl`).
    public init(control: @escaping @Sendable (_ method: String, _ params: [String: JSONValue], _ callerApp: String) async throws(AppHostCapabilityError) -> JSONValue) {
        self.control = control
    }

    public var families: Set<String> { ["browser.page"] }

    public func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
        guard request.op == "browser.page.eval" else { throw .unsupported(request.op) }
        guard let script = request.params["script"]?.stringValue, !script.isEmpty else {
            throw AppHostCapabilityError(code: "invalid_params", message: "browser.page.eval needs a script")
        }
        guard script.utf8.count <= Self.maxScript else {
            throw AppHostCapabilityError(code: "invalid_params", message: "a page script is at most \(Self.maxScript) bytes")
        }
        var params: [String: JSONValue] = ["script": .string(script)]
        if let tab = request.params["tab"]?.stringValue, !tab.isEmpty { params["tab"] = .string(tab) }
        return AppJSON(try await control("browser.page.eval", params, request.app))
    }
}
