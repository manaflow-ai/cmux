import AppKit
import CmuxNextAccounts
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCodeRouter
import CmuxNextSettings
import Foundation

/// The App side of the agent pane's missing-access card (``AgentPaneAccessProviding``,
/// paid-plan.md sections 4 and 5), one per app:
/// - Add API key: the native sheet (``AgentPaneAPIKeySheet``), the key saved in the Mac's Keychain
///   (``ProviderKeyStoring``, where Settings > Accounts lists it) and handed to acpmux's Keychain
///   item for the harness (`_acpmux/harness/secret/set`; acpmux reads only its own items, never the
///   app's), then a `direct-api-key` route that sends it by reference (`_acpmux/route/add`). The page
///   binds the chat to the route it answers.
/// - cmux credits: the balance and top-up on the cmux cloud API (``CloudCreditsClient``) as the
///   signed-in person; the payment page opens by ``BillingCheckoutOpener``'s rule (the cmux browser
///   when it holds a Stripe Link sign-in, else the default browser); live payment pages are refused
///   (``BillingLivePolicy``); the wait for a paid top-up is ``CloudCreditsWaiter``.
@MainActor
final class AgentPaneAccessService: AgentPaneAccessProviding {
    private unowned let services: AppServices
    private let keys: any ProviderKeyStoring

    init(services: AppServices, keys: any ProviderKeyStoring) {
        self.services = services
        self.keys = keys
    }

    func respond(to request: AgentPaneAccessRequest, acpmuxSocket: String?) async -> AgentPaneAccessReply {
        switch request {
        case .addKey(let harness, let family): return await addKey(harness: harness, family: family ?? harness)
        case .creditsState: return await creditsState()
        case .creditsTopUp(let usd): return await topUp(usd: usd)
        case .creditsWait(let above, let session): return await wait(above: above, session: session)
        }
    }

    // MARK: API key

    private func addKey(harness: String, family: String) async -> AgentPaneAccessReply {
        guard let provider = AgentPaneAPIKeyProvider(family: family) else {
            return .failure(code: "access.key_unsupported", message: AgentPaneAccessStrings.keyUnsupported)
        }
        guard let key = await AgentPaneAPIKeySheet(window: services.windows.active?.window).ask(for: provider.provider) else {
            return .success(["cancelled": true])
        }
        do {
            try keys.save(key, for: provider.provider)
        } catch {
            return .failure(code: "access.keychain", message: AgentPaneAccessStrings.keychainFailed)
        }
        let center = services.agentHarnesses
        do {
            let item = try await center.setSecret(id: harness, key: provider.environmentKey, value: key)
            try await center.addRoute(id: provider.routeID, [
                "name": "\(provider.provider.displayName) API key",
                "kind": "direct-api-key",
                "families": [family],
                "auth": "api-key",
                "secret": "keychain:\(item)",
            ])
        } catch AgentHarnessFailure.noDaemon {
            return .failure(code: "access.unavailable", message: AgentPaneAccessStrings.noAgentService)
        } catch {
            return .failure(code: "access.failed", message: AgentHarnessCenter.text(error))
        }
        return .success(["routeId": .string(provider.routeID)])
    }

    // MARK: cmux credits

    private var credits: CloudCreditsClient {
        let auth = services.cloud.auth
        return CloudCreditsClient(baseURL: services.feed.apiBaseURL, token: { @MainActor in
            guard auth.isSignedIn else { throw CloudCreditsError.notSignedIn }
            return try await auth.tokens().access
        })
    }

    private func creditsState() async -> AgentPaneAccessReply {
        do {
            let balance = try await credits.balance()
            return .success(["available_usd": .number(balance.availableUSD), "amounts_usd": .array(balance.amountsUSD.map { .number(Double($0)) }),
                             "signed_in": true])
        } catch .notSignedIn {
            return .success(["signed_in": false])
        } catch {
            return Self.failure(error)
        }
    }

    private func topUp(usd: Int) async -> AgentPaneAccessReply {
        let client = credits
        do {
            // The balance before the payment: the wait ends once it is above this.
            let before = (try? await client.balance())?.availableUSD ?? 0
            let url = try await client.topUp(usd: usd)
            if BillingLivePolicy.shipped.refuses(url) { return .failure(code: "billing.live_off", message: BillingStrings.liveOff) }
            let opened = try await AppControl.openBillingPage(url, .auto, services)
            var value: [String: JSONValue] = ["before_usd": .number(before), "opened_in": opened["opened_in"] ?? .null]
            if let session = CloudCreditsClient.checkoutSession(url) { value["session"] = .string(session) }
            return .success(value)
        } catch let error as CloudCreditsError {
            return Self.failure(error)
        } catch {
            return .failure(code: "billing.unavailable", message: AgentPaneAccessStrings.billingFailed)
        }
    }

    private func wait(above: Double, session: String?) async -> AgentPaneAccessReply {
        let client = credits
        let waiter = CloudCreditsWaiter(balance: { try await client.balance().availableUSD },
                                        grant: { await client.grant(session: $0) })
        do {
            switch try await waiter.wait(above: above, session: session) {
            case .rose(let available): return .success(["available_usd": .number(available)])
            case .timedOut(let available): return .success(["timedOut": true, "available_usd": .number(available)])
            }
        } catch let error as CloudCreditsError {
            return Self.failure(error)
        } catch {
            return .success(["timedOut": true])
        }
    }

    private static func failure(_ error: CloudCreditsError) -> AgentPaneAccessReply {
        switch error {
        case .notSignedIn: .failure(code: "not_signed_in", message: AgentPaneAccessStrings.notSignedIn)
        case .http(_, let code, let message): .failure(code: code ?? "billing.unavailable", message: message ?? AgentPaneAccessStrings.billingFailed)
        case .badResponse, .transport: .failure(code: "billing.unavailable", message: AgentPaneAccessStrings.billingFailed)
        }
    }
}
