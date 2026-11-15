import CmuxNextCompat
import CmuxNextControl
import CmuxNextSettings
import Foundation

// `keys.request`: what `cmux keys request NAME --purpose TEXT [--hosts ...] [--ttl ...]` sends
// (cmux-tui cli/key_broker.rs). The agent asks the person for a key it cannot make itself; the
// request waits in Settings > Keys (``KeyRequests``, design/settings-keys.md) behind one banner
// that never takes focus, and a click on it opens Settings > Keys. The person types the value
// there; it goes only to `cmux keys put` on stdin (``SettingsKeys``), and this answers the agent
// `{stored: true, name}`: never the value. Decline answers code `declined`. The CLI waits with
// no deadline of its own; the request ends as cancelled when its connection drops (Ctrl-C), when
// the same agent or another asks again for the same name, or when 16 others wait.
extension AppControl {
    func registerKeysMethods(_ services: AppServices) {
        service?.router.register([
            ControlMethod.async("keys.request") { call in
                let ask = try KeyRequestParams(call.params)
                let requests = await MainActor.run { KeyRequests.app }
                // A closed connection (Ctrl-C) ends the request: nobody waits for the answer.
                let waiting = Task { @MainActor in
                    await requests.ask(ask, added: { id in KeyRequestNotices.post(id: id, ask: ask, services: services) })
                }
                let token = ControlConnectionClosures.shared.add(call.connection) { waiting.cancel() }
                defer { ControlConnectionClosures.shared.remove(token) }
                let outcome = await withTaskCancellationHandler { await waiting.value } onCancel: { waiting.cancel() }
                switch outcome {
                case .stored(let name): return .object(["stored": .bool(true), "name": .string(name)])
                case .declined:
                    throw ControlError(code: "declined", message: "The person declined the request for \(ask.name)",
                                       data: ["name": .string(ask.name)])
                case .cancelled:
                    throw ControlError(code: "cancelled", message: "The request for \(ask.name) ended before the person answered",
                                       data: ["name": .string(ask.name)])
                }
            }.withDeadline(.fixed(KeyRequests.longestWait)),
        ])
    }
}

/// `keys.request`'s params, checked: `{name, purpose, hosts, ttl, requester, caller?}`.
nonisolated struct KeyRequestParams: Sendable, Equatable {
    var name: String
    var purpose: String
    var hosts: [String]
    var ttl: String?
    var requester: String

    init(name: String, purpose: String, hosts: [String] = [], ttl: String? = nil, requester: String) {
        self.name = name
        self.purpose = purpose
        self.hosts = hosts
        self.ttl = ttl
        self.requester = requester
    }

    init(_ params: [String: JSONValue]) throws {
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

extension KeyRequests {
    /// How long a request may wait for the person: a week, so the CLI's own wait (none) decides.
    nonisolated static let longestWait: Duration = .seconds(7 * 24 * 3_600)

    /// Adds `ask` and waits for its end; `added` runs once with its id (the banner). A cancel of the
    /// calling task (the asker's connection dropped, the request's deadline) ends it as cancelled.
    func ask(_ ask: KeyRequestParams, added: (String) -> Void = { _ in }) async -> Outcome {
        let box = AskBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                guard !Task.isCancelled else { return continuation.resume(returning: .cancelled) }
                let id = add(name: ask.name, purpose: ask.purpose, hosts: ask.hosts, ttl: ask.ttl, requester: ask.requester) { outcome in
                    continuation.resume(returning: outcome)
                }
                box.id = id
                added(id)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if let id = box.id { self?.finish(id, .cancelled) }
            }
        }
    }

    @MainActor private final class AskBox {
        var id: String?
    }
}

/// The banner of a key request: "<agent> asks for a key", then "NAME: purpose". One per request,
/// withdrawn when it ends; a click opens Settings > Keys. Posting never moves focus.
@MainActor
enum KeyRequestNotices {
    static let prefix = "cmux.keys.request."
    static let settingsRoute = "#/settings/keys"

    static func post(id: String, ask: KeyRequestParams, services: AppServices) {
        let agent = actorLabel(ask.requester) ?? String(localized: "keys.request.someone", defaultValue: "An agent", table: "Keys", bundle: .module)
        let title = String(format: String(localized: "keys.request.title", defaultValue: "%@ asks for a key", table: "Keys", bundle: .module), agent)
        let purpose = ask.purpose.count > 200 ? String(ask.purpose.prefix(199)) + "…" : ask.purpose
        services.notifications.desktop.post(id: prefix + id, title: title, body: "\(ask.name): \(purpose)", surface: nil, workspace: nil,
                                            defaultSound: true)
        let requests = KeyRequests.app
        // task-owner: one wait per banner; ends with the request
        Task { @MainActor [weak services] in
            for await waiting in ObservationStream({ requests.request(id) != nil }) where !waiting {
                services?.notifications.desktop.withdraw([prefix + id])
                return
            }
        }
    }

    /// A click on banner `id`: Settings > Keys. False when it is no key request's.
    static func open(banner id: String, services: AppServices?) -> Bool {
        guard id.hasPrefix(prefix) else { return false }
        try? services?.settingsWindow.show(section: nil, route: settingsRoute)
        return true
    }

    /// Who asked, as the CLI names it (`CLAUDE_CODE_SESSION_ID=…`, `user=leo`), for a person:
    /// the agent's product and the start of its session id, or the user's name (keys.ts `actorLabel`).
    nonisolated static func actorLabel(_ by: String) -> String? {
        let text = by.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text != "unknown" else { return nil }
        guard let at = text.firstIndex(of: "=") else { return text }
        let variable = String(text[..<at]), value = String(text[text.index(after: at)...])
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
