import Foundation

public enum VMClientError: Error, CustomStringConvertible {
    case notSignedIn
    case sessionRefreshFailed
    case backendUnreachable(url: String, detail: String)
    case httpStatus(Int, String)
    case malformedResponse(String)
    /// An MDM profile forces `DisableCloud`; no request was attempted.
    case disabledByManagedPolicy
    /// The macOS Cloud integration is disabled by its remote runtime flag;
    /// no request was attempted.
    case cloudMachinesDisabled
    /// The control plane answered 501 to `pause`/`resume`: this provider has no such operation.
    case lifecycleUnsupported(action: String)

    public var description: String {
        switch self {
        case .notSignedIn:
            return """
                You are not signed in to cmux.

                What to do:
                  cmux auth login
                  cmux auth status
                """
        case .sessionRefreshFailed:
            return """
                You are signed in, but cmux could not refresh your session (network or server issue).

                What to do:
                  Retry in a moment.
                  If it keeps failing, run `cmux auth status` to check your session.
                """
        case .backendUnreachable(let url, let detail):
            return """
                Cannot reach the cmux Cloud VM service at \(url).

                What to do:
                  Start the cmux web server, then retry.
                  If you are using a local development build, check its Cloud VM service URL before launching cmux.

                Details:
                  \(detail)
                """
        case .httpStatus(let code, let body):
            return formattedCloudVMHTTPError(status: code, body: body)
        case .lifecycleUnsupported(let action):
            return """
                This provider cannot \(action) machines.

                What to do:
                  Machines here stay available until you delete them; `cmux vm rm <id>` when the work is done.
                """
        case .disabledByManagedPolicy:
            return String(
                localized: "cloud.managed.disabled",
                defaultValue: "Cloud Machines are disabled by your administrator."
            )
        case .cloudMachinesDisabled:
            return String(
                localized: "cloud.feature.disabled",
                defaultValue: "Cloud Machines are temporarily unavailable."
            )
        case .malformedResponse(let message):
            return """
                The cmux Cloud VM backend returned a response this client could not read.

                What to do:
                  Update cmux to the latest build and retry.
                  If this keeps happening, copy the details below and contact support.

                Details:
                  \(message)
                """
        }
    }
}
