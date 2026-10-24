import CmuxNextBrowser
import Foundation
import WebKit

/// `tab.setContentRules {targetId, session, lists}`: installs a host
/// session's domain policy on a WebKit tab as content rule lists. The host
/// compiles the policy (cmux-browser-host `policy/webkit_rules.rs`); this
/// only compiles each list with WebKit and swaps it on the tab's content
/// controller. `lists: null` removes the session's lists. Each session's
/// lists are kept apart, so two sessions on one tab both apply (a request
/// either blocks does not load). A list WebKit cannot compile fails the call
/// `invalid` with WebKit's message, and the host then fails the session's
/// calls closed.
@MainActor
struct WebKitContentRules {
    let driver: WebKitDriver

    func set(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let (tab, session) = try driver.target(params)
        let owner = try params.string("session")
        let controller = tab.webView.configuration.userContentController
        var compiled: [WKContentRuleList] = []
        for item in try params.array("lists") {
            guard case .object(let fields) = item,
                  let identifier = fields["identifier"]?.stringValue, !identifier.isEmpty,
                  let rules = fields["rules"] else {
                throw DriverError(.invalid, "tab.setContentRules: lists: expected [{identifier, rules}]")
            }
            compiled.append(try await Self.compile(identifier: identifier, rules: rules))
        }
        for old in session.contentRules[owner] ?? [] { controller.remove(old) }
        for list in compiled { controller.add(list) }
        session.contentRules[owner] = compiled.isEmpty ? nil : compiled
        return .null
    }

    static func compile(identifier: String, rules: DriverJSON) async throws(DriverError) -> WKContentRuleList {
        guard let data = try? JSONSerialization.data(withJSONObject: rules.foundationValue),
              let text = String(data: data, encoding: .utf8) else {
            throw DriverError(.invalid, "tab.setContentRules: \(identifier): rules are not JSON")
        }
        guard let store = WKContentRuleListStore.default() else {
            throw DriverError(.unsupported, "tab.setContentRules: WebKit has no content rule store")
        }
        do {
            guard let list = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: text) else {
                throw DriverError(.invalid, "tab.setContentRules: \(identifier) could not be compiled")
            }
            return list
        } catch let error as DriverError {
            throw error
        } catch {
            throw DriverError(.invalid, "tab.setContentRules: \(identifier) could not be compiled: \(error.localizedDescription)")
        }
    }
}
