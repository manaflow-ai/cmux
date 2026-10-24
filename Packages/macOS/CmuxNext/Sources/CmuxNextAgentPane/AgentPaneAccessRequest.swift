import Foundation

/// The missing-access card's host calls (paid-plan.md section 4, webviews MissingAccessNotice.tsx).
/// Fixed param keys; any other is refused, so a key typed in the page can never ride along.
///
/// - `access.addKey {harness, family?}`: the App's native sheet asks for an API key, stores it in the
///   Mac's Keychain and answers the acpmux route that sends it, `{routeId}`, or `{cancelled: true}`.
///   Only with the person's click.
/// - `credits.state {}`: the cmux credits balance, `{available_usd, amounts_usd, signed_in}`.
/// - `credits.topup {usd}`: a Checkout page for `usd` dollars of credits, opened where
///   ``BillingCheckoutOpener`` says; answers `{session?, before_usd, opened_in}`. Only with a click.
/// - `credits.wait {above, session?}`: answers `{available_usd}` once the balance is above `above`,
///   or `{timedOut: true, available_usd}` at its deadline.
public nonisolated enum AgentPaneAccessRequest: Equatable, Sendable {
    case addKey(harness: String, family: String?)
    case creditsState
    case creditsTopUp(usd: Int)
    case creditsWait(above: Double, session: String?)

    /// The methods, for ``AgentPageOps`` and ``AgentPaneRequest``.
    public static let methods: Set<String> = ["access.addKey", "credits.state", "credits.topup", "credits.wait"]

    static let knownParams: [String: Set<String>] = [
        "access.addKey": ["harness", "family"],
        "credits.state": [],
        "credits.topup": ["usd"],
        "credits.wait": ["above", "session"],
    ]

    /// The request for `method` and `params`, nil when they break the contract.
    init?(method: String, params: [String: Any]?) {
        guard let known = Self.knownParams[method] else { return nil }
        let params = params ?? [:]
        guard Set(params.keys).isSubset(of: known) else { return nil }
        switch method {
        case "access.addKey":
            guard let harness = Self.id(params["harness"]) else { return nil }
            let family = params["family"].map(Self.id)
            if case .some(.none) = family { return nil }
            self = .addKey(harness: harness, family: family ?? nil)
        case "credits.state":
            self = .creditsState
        case "credits.topup":
            // A whole number of dollars, as the payment page sells them; never a string.
            guard let number = params["usd"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let usd = Int(exactly: number.doubleValue), (1...1000).contains(usd) else { return nil }
            self = .creditsTopUp(usd: usd)
        case "credits.wait":
            guard let number = params["above"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
            let session = params["session"] as? String
            if params["session"] != nil, session.flatMap(Self.session) == nil { return nil }
            self = .creditsWait(above: number.doubleValue, session: session)
        default:
            return nil
        }
    }

    /// The method this request came from.
    var method: String {
        switch self {
        case .addKey: "access.addKey"
        case .creditsState: "credits.state"
        case .creditsTopUp: "credits.topup"
        case .creditsWait: "credits.wait"
        }
    }

    /// A sheet or a payment page opens only on the person's click.
    var needsGesture: Bool {
        switch self {
        case .addKey, .creditsTopUp: true
        case .creditsState, .creditsWait: false
        }
    }

    /// A harness id or family: an acpmux profile file name, never a command.
    private static func id(_ raw: Any?) -> String? {
        guard let id = raw as? String, !id.isEmpty, id.utf8.count <= 128,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else { return nil }
        return id
    }

    /// A Checkout session id (`cs_test_…`).
    private static func session(_ raw: String) -> String? {
        guard raw.hasPrefix("cs_"), raw.utf8.count <= 256,
              raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
        return raw
    }
}
