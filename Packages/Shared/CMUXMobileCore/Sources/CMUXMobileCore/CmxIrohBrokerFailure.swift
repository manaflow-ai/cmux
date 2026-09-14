/// Bounded, non-secret metadata returned by the authenticated Iroh broker.
///
/// The broker keeps the public error response coarse, but a status/code/request
/// ID tuple lets support distinguish an outage from a local policy failure.
public struct CmxIrohBrokerFailure: Equatable, Sendable, CustomStringConvertible {
    public let statusCode: Int
    public let code: String?
    public let requestID: String?

    public init(statusCode: Int, code: String?, requestID: String?) {
        self.statusCode = statusCode
        self.code = Self.safeCode(code)
        self.requestID = Self.bounded(requestID)
    }

    public var description: String {
        var result = "HTTP \(statusCode)"
        if let code {
            result += " (\(code))"
        }
        if let requestID {
            result += " requestID=\(requestID)"
        }
        return result
    }

    private static func bounded(_ value: String?) -> String? {
        guard let value,
              (1 ... 128).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({
                  switch $0.value {
                  case 48 ... 57, 65 ... 90, 97 ... 122, 45, 46, 58, 95:
                      true
                  default:
                      false
                  }
              }) else {
            return nil
        }
        return value
    }

    private static func safeCode(_ value: String?) -> String? {
        guard let value,
              let category = value.split(separator: ":", maxSplits: 1).first
        else { return nil }
        switch category {
        case "relay_policy_unavailable", "rate_limited",
             "authentication_unavailable", "preference_conflict":
            return String(category)
        case "invalid_binding_request_proof", "binding_request_proof_required":
            return "authorization_failed"
        default:
            return nil
        }
    }
}
