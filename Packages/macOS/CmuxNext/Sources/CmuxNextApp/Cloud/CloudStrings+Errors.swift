import CmuxNextCloud
import Foundation

/// The text a person reads for a Cloud failure: what failed, then the next
/// step. Keys live in Resources/Cloud.xcstrings with every app locale.
extension CloudStrings {
    /// One Cloud error as a person reads it, never a Swift dump: a server
    /// refusal is its message, its next step and "(trace …)"; the other
    /// ``CloudAPIError`` cases say what to do; a link error reads as
    /// ``CloudAppLinks/endedMessage(_:)``. Logs keep `String(describing:)`.
    static func errorText(_ error: any Error) -> String {
        switch error {
        case let error as CloudAPIError: apiErrorText(error)
        case let error as CloudLinkError: CloudAppLinks.endedMessage(error)
        case let error as ActionFailure: error.message
        case let error as any LocalizedError: error.errorDescription ?? String(describing: error)
        default: String(describing: error)
        }
    }

    /// A ``CloudAPIError`` as a person reads it. Nonisolated: the approvals
    /// route maps its failures off the main actor.
    nonisolated static func apiErrorText(_ error: CloudAPIError) -> String {
        switch error {
        case .notSignedIn: signInFirst
        case .noBackend: localBackend
        // The path stays in the log (`description`): a person gets no raw API path.
        case .timedOut: apiTimedOut
        case .transport(let detail): apiUnreachable(detail)
        case .decoding: apiUnreadable
        // The server's own (localized) refusal, else the app's Pro copy.
        case let .planRequired(message, _, plan): message ?? (plan == "pro" ? proRequiredBody : error.text())
        case let .http(status, code, message, action, traceId):
            CloudAPIError.http(status: status, code: code, message: message,
                               action: action.flatMap { isCallerOnly($0) ? nil : $0 }, traceId: traceId)
                .text(trace: trace)
        }
    }

    /// Whether a server `action` is written for an API caller or the classic
    /// `cmux vm` CLI, not a person in this app: "List your rules with GET
    /// /api/vm/firewall", "Enroll it with POST /api/vm/tunnel", "Request the
    /// attach endpoint with transport …", "Run `cmux vm ls`"
    /// (`web/services/vms/routeHelpers.ts`). Such a failure shows its
    /// message and trace id without the action; the log keeps it.
    nonisolated static func isCallerOnly(_ action: String) -> Bool {
        ["cmux vm ", "/api/vm", "attach endpoint"].contains { action.contains($0) }
    }

    /// The support reference after a Cloud server message.
    nonisolated static func trace(_ id: String) -> String {
        String(format: String(localized: "cloud.error.trace", defaultValue: "(trace %@)", table: "Cloud", bundle: .module), id)
    }

    nonisolated static var apiTimedOut: String {
        String(localized: "cloud.error.timedOut",
               defaultValue: "cmux Cloud didn't answer in time. Try again; if it keeps happening, run `cmux cloud diagnostics`.",
               table: "Cloud", bundle: .module)
    }

    /// `detail` is the system's own (localized) network error text.
    nonisolated static func apiUnreachable(_ detail: String) -> String {
        String(format: String(localized: "cloud.error.unreachable", defaultValue: "Couldn't reach cmux Cloud (%@). Check your network, then try again.",
                              table: "Cloud", bundle: .module), detail)
    }

    nonisolated static var apiUnreadable: String {
        String(localized: "cloud.error.unreadable", defaultValue: "cmux Cloud sent an answer this version of cmux can't read. Update cmux, then try again.",
               table: "Cloud", bundle: .module)
    }
}
