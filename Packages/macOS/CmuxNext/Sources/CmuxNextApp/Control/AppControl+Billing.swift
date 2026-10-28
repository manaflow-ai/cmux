import AppKit
import CmuxNextCodeRouter
import CmuxNextControl
import CmuxNextPages
import CmuxNextSettings
import Foundation
import CmuxNextAccounts

// `billing.checkout|portal|status`: the methods `cmux billing checkout|portal|status`
// sends (plans/cmux-next/paid-product-DESIGN.md). The app holds the Stack session:
// it asks cmux.com (`POST /api/billing/checkout`, the native checkout classic cmux
// uses) for a Stripe Checkout session bound to the signed-in account, then opens
// it in a cmux browser tab when that browser is signed in to Stripe Link, else in
// the default browser. No card data passes through cmux and nothing is charged
// until the person pays on the Stripe page, so an agent may start a checkout.
// Opening the page is the command's purpose; nothing else moves focus.
extension AppControl {
    func registerBillingMethods(_ services: AppServices) {
        let network: ControlMethod.Deadline = .fixed(.seconds(22))
        service?.router.register([
            ControlMethod.async("billing.checkout") { call in
                let params = call.params
                let request: BillingCheckoutRequest
                do {
                    request = try BillingCheckoutRequest(plan: params["plan"]?.stringValue ?? "pro",
                                                         team: (params["teamId"] ?? params["team_id"])?.stringValue)
                } catch let invalid as BillingCheckoutRequest.Invalid {
                    throw ControlError.invalidParams(invalid.description)
                }
                let open = try Self.openRequest(params)
                let client = try await Self.billingClient(services)
                let answer = try await Self.webJSON { try await client.request("POST", "/api/billing/checkout", body: request.body) }
                guard case .object(let object) = answer, let raw = object["url"]?.stringValue, let url = URL(string: raw),
                      url.scheme?.lowercased() == "https" else {
                    throw ControlError(code: "bad_response", message: BillingStrings.badResponse)
                }
                if BillingLivePolicy.shipped.refuses(url) { throw ControlError(code: "billing.live_off", message: BillingStrings.liveOff) }
                var result = object
                result["mode"] = .string(StripeCheckoutMode(url: url).rawValue)
                return .object(result.merging(try await Self.openBillingPage(url, open, services)) { _, opened in opened })
            }.withDeadline(network),
            ControlMethod.async("billing.portal") { call in
                let params = call.params
                let open = try Self.openRequest(params)
                let base = await MainActor.run { services.cloud.configuration.apiBaseURL }
                var components = URLComponents(url: base.appending(path: "dashboard/billing"), resolvingAgainstBaseURL: false)
                if let team = (params["teamId"] ?? params["team_id"])?.stringValue, !team.isEmpty {
                    components?.queryItems = [URLQueryItem(name: "team", value: team)]
                }
                guard let url = components?.url else { throw ControlError(code: "bad_response", message: BillingStrings.badResponse) }
                return .object(["url": .string(url.absoluteString)].merging(try await Self.openBillingPage(url, open, services)) { _, opened in opened })
            }.withDeadline(network),
            ControlMethod.async("billing.status") { call in
                let client = try await Self.billingClient(services)
                var path = "/api/billing/plan"
                if let team = (call.params["teamId"] ?? call.params["team_id"])?.stringValue, !team.isEmpty,
                   let encoded = team.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                    path += "?teamId=" + encoded
                }
                let finalPath = path
                return try await Self.webJSON { try await client.request("GET", finalPath) }
            }.withDeadline(network),
        ])
    }

    nonisolated private static func openRequest(_ params: [String: JSONValue]) throws -> BillingOpenRequest {
        guard let open = BillingOpenRequest(word: params["open"]?.stringValue) else { throw ControlError.invalidParams(BillingStrings.badOpen) }
        return open
    }

    /// The signed-in cmux.com client (``CodeRouterClient`` authenticates any `/api/*` call as the user).
    nonisolated private static func billingClient(_ services: AppServices) async throws -> CodeRouterClient {
        try await MainActor.run {
            if let refusal = Self.policyRefusal("billing.checkout", disabled: services.registry.disabledFeatures) { throw refusal }
            guard let client = services.accounts.client else { throw ControlError(code: "unavailable", message: BillingStrings.unavailable) }
            guard services.cloud.isSignedIn else { throw ControlError(code: "not_signed_in", message: BillingStrings.notSignedIn) }
            return client
        }
    }

    /// One cmux.com call as JSON; its error code (`team_admin_required`, `plan_unavailable`, …) passes through.
    nonisolated private static func webJSON(_ call: @Sendable () async throws -> Data) async throws -> JSONValue {
        do {
            let data = try await call()
            return data.isEmpty ? .object([:]) : try JSONValue.parse(data)
        } catch let error as CodeRouterError {
            switch error {
            case .notSignedIn: throw ControlError(code: "not_signed_in", message: BillingStrings.notSignedIn)
            case .scopeChanged: throw ControlError(code: "scope_changed", message: error.description)
            case .timedOut: throw ControlError(code: "timeout", message: error.description)
            case .http(let status, let code, _): throw ControlError(code: code ?? "http_\(status)", message: error.description)
            case .transport: throw ControlError(code: "unavailable", message: error.description)
            case .decoding: throw ControlError(code: "bad_response", message: BillingStrings.badResponse)
            }
        }
    }

    /// Opens `url` where ``BillingCheckoutOpener`` says and answers `opened_in`,
    /// `link_session` and the cmux browser `profile` it checked.
    nonisolated private static func openBillingPage(_ url: URL, _ request: BillingOpenRequest,
                                                    _ services: AppServices) async throws -> [String: JSONValue] {
        let session = await MainActor.run { BrowserProfileLinkSession(services: services) }
        let profile = await session.profileForNewTab()
        let link = request == .printOnly ? false : await session.hasSession(profile: profile)
        return await MainActor.run {
            let handler = DefaultBrowserLink.handler(url)
            let opener = BillingCheckoutOpener(defaultBrowserIsCmux: handler?.isCmux ?? false,
                                               cmuxBrowserEnabled: LinkRouter.shared.routing().browserEnabled)
            let target = opener.decide(request, linkSession: link)
            switch target {
            case .cmuxBrowser:
                LinkRouter.shared.open(url, in: .cmuxBrowser)
            case .defaultBrowser:
                if let handler, !handler.isCmux { LinkRouter.shared.open(url, withApplicationAt: handler.appURL) } else { LinkRouter.shared.open(url, in: .system) }
            case .nowhere:
                break
            }
            return ["opened_in": .string(target.rawValue), "link_session": .bool(link),
                    "profile": .string(services.browserProfiles.displayName(profile))]
        }
    }
}
