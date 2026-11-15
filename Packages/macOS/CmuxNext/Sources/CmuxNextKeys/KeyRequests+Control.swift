package import CmuxNextControl
package import CmuxNextNotifications
package import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// `keys.request`: what `cmux keys request NAME --purpose TEXT [--hosts ...] [--ttl ...]` sends
/// (cmux-tui cli/key_broker.rs). The agent asks the person for a key it cannot make itself; the
/// request waits in Settings > Keys (``KeyRequests``, design/settings-keys.md) behind one banner
/// that never takes focus (``KeyRequests/postBanners(on:)``), and a click on it opens Settings > Keys. The
/// person types the value there; it goes only to `cmux keys put` on stdin (``SettingsKeys``), and
/// this answers the agent `{stored: true, name}`: never the value. Decline answers code
/// `declined`. The CLI waits with no deadline of its own; the request ends as cancelled when its
/// connection drops (Ctrl-C), when the same agent or another asks again for the same name, when
/// 16 others wait, or after ``KeyRequests/longestWait``.
extension KeyRequests {
    /// The `keys.request` control method, answered from this list.
    package var controlMethod: ControlMethod {
        let requests = self
        return ControlMethod.async("keys.request") { call in
            let ask = try KeyRequestParams(call.params)
            let id = KeyRequests.newID()
            // A closed connection (Ctrl-C) ends the request: nobody waits for the answer.
            let abandon: @MainActor @Sendable () -> Void = { [weak requests] in requests?.abandon(id) }
            let token = ControlConnectionClosures.shared.add(call.connection) { MainDelivery().run(abandon) }
            defer { ControlConnectionClosures.shared.remove(token) }
            switch await requests.ask(ask, id: id) {
            case .stored(let name): return .object(["stored": .bool(true), "name": .string(name)])
            case .declined:
                throw ControlError(code: "declined", message: "The person declined the request for \(ask.name)",
                                   data: ["name": .string(ask.name)])
            case .cancelled:
                throw ControlError(code: "cancelled", message: "The request for \(ask.name) ended before the person answered",
                                   data: ["name": .string(ask.name)])
            }
        }.withDeadline(.fixed(KeyRequests.longestWait))
    }
}

/// `keys.request`'s params, checked: `{name, purpose, hosts, ttl, requester, caller?}`.
package nonisolated struct KeyRequestParams: Sendable, Equatable {
    package var name: String
    package var purpose: String
    package var hosts: [String]
    package var ttl: String?
    package var requester: String

    package init(name: String, purpose: String, hosts: [String] = [], ttl: String? = nil, requester: String) {
        self.name = name
        self.purpose = purpose
        self.hosts = hosts
        self.ttl = ttl
        self.requester = requester
    }

    package init(_ params: [String: JSONValue]) throws {
        guard let name = params["name"]?.stringValue, KeysCLI.validName(name) else {
            throw ControlError.invalidParams("keys.request requires params.name: A-Z, 0-9 and _, starting with a letter or _, at most 80")
        }
        let purpose = params["purpose"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !purpose.isEmpty, purpose.count <= 2_000 else {
            throw ControlError.invalidParams("keys.request requires params.purpose (what the key is for), at most 2000 characters")
        }
        var hosts: [String] = []
        if case .array(let items)? = params["hosts"] {
            for case .string(let host) in items {
                let trimmed = host.trimmingCharacters(in: .whitespaces).lowercased()
                if !trimmed.isEmpty, !hosts.contains(trimmed) { hosts.append(trimmed) }
            }
        }
        guard hosts.count <= 32 else { throw ControlError.invalidParams("keys.request takes at most 32 hosts") }
        let ttl = params["ttl"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let requester = params["requester"]?.stringValue.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) } ?? "unknown"
        self.init(name: name, purpose: purpose, hosts: hosts, ttl: ttl, requester: requester)
    }
}

/// The banner of a key request: "<agent> asks for a key", then "NAME: purpose". One per request,
/// withdrawn when it ends; a click opens Settings > Keys (the App's banner click routes ids with
/// ``bannerPrefix`` to ``settingsRoute``). Posting never moves focus.
extension KeyRequests {
    package nonisolated static let bannerPrefix = "cmux.keys.request."
    package nonisolated static let settingsRoute = "#/settings/keys"

    /// Posts each new request's banner on `notifier` and withdraws it when the request ends. Answers self.
    package func postBanners(on notifier: DesktopNotifier) -> KeyRequests {
        onAdded = { [weak notifier] request in
            notifier?.post(id: Self.bannerPrefix + request.id, title: request.bannerTitle, body: request.bannerBody, surface: nil,
                           workspace: nil, defaultSound: true)
        }
        onEnded = { [weak notifier] id in notifier?.withdraw([Self.bannerPrefix + id]) }
        return self
    }

    /// Whether banner `id` is a key request's.
    package nonisolated static func isBanner(_ id: String) -> Bool { id.hasPrefix(bannerPrefix) }

    /// Who asked, as the CLI names it (`CLAUDE_CODE_SESSION_ID=…`, `user=leo`), for a person:
    /// the agent's product and the start of its session id, or the user's name (keys.ts `actorLabel`).
    package nonisolated static func actorLabel(_ by: String) -> String? {
        let text = by.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text != "unknown" else { return nil }
        let parts = text.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let variable = parts.first.map(String.init), let value = parts.last.map(String.init) else { return text }
        let short = String(value.prefix(8))
        switch variable {
        case "user": return value
        case "CLAUDE_CODE_SESSION_ID": return "Claude Code · \(short)"
        case "CODEX_SESSION_ID": return "Codex · \(short)"
        case "CMUX_SESSION_ID": return "cmux · \(short)"
        case "ACPMUX_SESSION": return "acpmux · \(short)"
        default: return value.isEmpty ? text : value
        }
    }
}

extension KeyRequests.Request {
    /// "<agent> asks for a key".
    package var bannerTitle: String {
        let agent = KeyRequests.actorLabel(requester)
            ?? String(localized: "keys.request.someone", defaultValue: "An agent", table: "Keys", bundle: .module)
        return String(format: String(localized: "keys.request.title", defaultValue: "%@ asks for a key", table: "Keys", bundle: .module), agent)
    }

    /// "NAME: purpose", the purpose cut at 200 characters.
    package var bannerBody: String {
        "\(name): " + (purpose.count > 200 ? String(purpose.prefix(199)) + "…" : purpose)
    }
}
