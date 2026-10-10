import CmuxNextApps
import Foundation

/// The `credential` provider family (cx-wb5.63) as one handler of the app
/// supervisor's provider channel (`AppsProviderChannel`, apps-v1): the
/// channel registers it on the verified app connection with the other
/// Mac-side families and answers each call on the connection it came on.
/// ``CloudCredentialRelay`` refuses any app but `cmux/cloud` and any op
/// family but `cloud.*`. `AppsService` attaches it only on the app server
/// link path (`CloudService.credentialOps`).
nonisolated struct CloudCredentialOps: AppHostCapabilityHandler {
    let relay: CloudCredentialRelay

    var families: Set<String> { [CloudCredentialRelay.family] }

    func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
        let answer = await relay.answer(app: request.app, op: request.op, params: request.params.daemonValue)
        if answer.ok { return AppJSON(answer.body) }
        throw AppHostCapabilityError(code: answer.body["code"]?.stringValue ?? "operation.failed",
                                     message: answer.body["message"]?.stringValue ?? "",
                                     retryable: answer.body["retryable"]?.boolValue ?? false,
                                     details: answer.body["details"].map(AppJSON.init))
    }
}
