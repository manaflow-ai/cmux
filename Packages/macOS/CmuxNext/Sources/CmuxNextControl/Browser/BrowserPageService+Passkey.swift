public import CmuxNextSettings
import Foundation

/// `browser.page.passkey` (`cmux browser <tab|right> passkey [SELECTOR]`): an
/// agent at a passkey step hands the ceremony to the person
/// (plans/cmux-next/agent-browser-passkey-DESIGN.md 3.2). Params: `tab`,
/// `selector` (the element that starts the ceremony, a selector or snapshot
/// ref; none when the page waits by itself), `agent`, `reason`. Answers
/// `request` and `status`: `triggered` when the tab was already in front,
/// else `pending` until the person clicks the banner, which brings the tab
/// forward focused and then clicks `selector`. `browser.page.passkey_status
/// {request}` reads `pending`, `expired` or `unknown` (answered or replaced).
extension BrowserPageService {
    func passkeyMethods() -> [ControlMethod] {
        guard let passkeys else { return [] }
        let engine = engine
        return [
            .async("browser.page.passkey") { call in
                let tab = try Self.tab(call)
                let selector = Self.optionalString(call, "selector")
                let agent = Self.optionalString(call, "agent") ?? "agent"
                let site = tab.url.flatMap { URL(string: $0)?.host() } ?? tab.url ?? ""
                let trigger: @Sendable () async throws -> Void = {
                    guard let selector else { return }
                    let value = try await Self.run(engine, .evaluate(BrowserPageScripts.click(selector, nil)), tab)["value"] ?? .null
                    if let error = value["error"]?.stringValue {
                        throw ControlError(code: "not_found", message: error, data: ["selector": .string(selector)])
                    }
                }
                let raised = try await passkeys.raise(tabID: tab.id, agent: agent, site: site,
                                                      reason: Self.optionalString(call, "reason"), trigger: trigger)
                var result = Self.base(tab)
                result["request"] = .string(raised.id)
                result["status"] = .string(raised.status.rawValue)
                return .object(result)
            },
            .async("browser.page.passkey_status") { call in
                let id = try Self.string(call, "request")
                return ["request": .string(id), "status": .string(await passkeys.status(id).rawValue)]
            },
        ]
    }
}
