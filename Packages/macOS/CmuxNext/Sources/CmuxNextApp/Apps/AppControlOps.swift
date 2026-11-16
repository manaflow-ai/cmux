import CmuxNextApps
import CmuxNextControl
import CmuxNextSettings
import Foundation

nonisolated extension ControlRouter {
    /// Runs one control method in process for a Mac-side app op (the
    /// CodeRouter app's and page's ops, `action.*`, `browser.page.*`): validation, targets, the
    /// work queue and the origin rule are the control socket's.
    func appControl(_ method: String, _ params: [String: JSONValue], callerApp: String? = nil) async throws(AppHostCapabilityError) -> JSONValue {
        switch await handle(ControlRequest(method: method, params: params, callerApp: callerApp), connection: .inProcess) {
        case .success(let value): return value
        case .failure(let error):
            throw AppHostCapabilityError(code: error.code, message: error.message, details: error.data.map(AppJSON.init))
        }
    }
}
