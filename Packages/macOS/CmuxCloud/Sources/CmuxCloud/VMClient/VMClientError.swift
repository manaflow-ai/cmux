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

extension VMClientError {
    /// The wait the control plane asked for before the same request is sent
    /// again, from a retryable answer's `retryAfterSeconds`; nil when the
    /// answer named none. Bounded so a malformed answer cannot park a retry.
    ///
    /// A `409 vm_access_grant_busy` names one second while another request
    /// holds this Mac's access lease; asking sooner only meets the same lease.
    public var serverRetryAfter: Duration? {
        guard case let .httpStatus(status, body) = self,
              status == 409 || status == 429 || status == 503,
              let data = body.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let seconds: Int?
        if let value = object["retryAfterSeconds"] as? Int {
            seconds = value
        } else if let value = object["retryAfterSeconds"] as? Double {
            // Bound before converting: an out-of-range Double traps in Int().
            guard value.isFinite, value > 0 else { return nil }
            seconds = Int(min(value, Double(Self.maximumServerRetryAfterSeconds)).rounded(.up))
        } else {
            seconds = nil
        }
        guard let seconds, seconds > 0 else { return nil }
        return .seconds(min(seconds, Self.maximumServerRetryAfterSeconds))
    }

    static let maximumServerRetryAfterSeconds = 60

    /// The JSON `error` code of an HTTP answer; nil for other errors or a
    /// body without one.
    public var serverErrorCode: String? {
        guard case let .httpStatus(_, body) = self,
              let data = body.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = (object["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty else { return nil }
        return code
    }
}
