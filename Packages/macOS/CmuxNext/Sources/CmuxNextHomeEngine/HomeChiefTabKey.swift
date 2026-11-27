public import CmuxNextDaemon
public import Foundation

/// The idempotency key of one chief tab creation (`origin` + `mutation_id`
/// of `new-conversation-tab`). A retry after a lost reply reuses the key, so
/// the store replays the first tab. Once the chief tab is seen, or the store
/// refuses the key because its tab closed, the next creation takes a new
/// key: the store never re-creates a closed chief tab under its old browser
/// id (one browser id belongs to at most one tab).
///
/// A class, so overlapping connects share one pending key: a connect that
/// starts while an earlier one still waits for its reply sends the same key.
@MainActor
public final class HomeChiefTabKey {
    /// The daemon's refusal of a key whose tab was closed.
    static let keyClosedCode = "frontend_browser_key_closed"

    private var pending: String?
    private let make: @Sendable () -> String

    public init(make: @escaping @Sendable () -> String = { "home-chief-tab-\(UUID().uuidString.lowercased())" }) {
        self.make = make
    }

    /// Whether a conversation tab shows `chief` in any of `workspaces`: the
    /// person may move the chief tab out of the home, and a moved tab still
    /// counts (a second chief tab is never created). `dock.chief_tab_open`.
    public static func isOpen(chief: String, in workspaces: [WorkspaceModel]) -> Bool {
        dockRule("dock.chief_tab_open", OpenRequest(chief: chief, workspaces: workspaces.map(DockWorkspace.init)), fallback: false)
    }

    /// The key of the next creation: the pending one, else a new one.
    func forCreate() -> String {
        step(.begin(chiefTabOpen: false, fresh: pending ?? make())).send ?? ""
    }

    /// The chief tab is present: the next creation takes a new key.
    func settle() { _ = step(.settle) }

    /// `key`'s creation ended (the tab exists, or the store refused the key
    /// because its tab closed). A newer pending key stays.
    func settle(_ key: String) { _ = step(.settleKey(key)) }

    /// One connect: nothing while the chief tab is open; else one keyed
    /// create through `send`. A `frontend_browser_key_closed` refusal (the
    /// pending key's tab was created and closed) is not shown: it retries once
    /// with a new key. Any other failure keeps the key pending. Returns
    /// whether it sent a create. The steps are `dock.chief_tab_key_step`.
    public func ensure(chiefTabOpen: Bool, send: (String) async throws -> Void) async throws -> Bool {
        var next = step(.begin(chiefTabOpen: chiefTabOpen, fresh: chiefTabOpen ? "" : pending ?? make())).send
        var retried = false
        while let key = next {
            do {
                try await send(key)
            } catch {
                var code: String?
                if case let DaemonError.command(_, _, failure, _, _) = error { code = failure }
                // A fresh key only when the refusal may retry under one (keeps `make` called as before).
                let fresh = !retried && code == Self.keyClosedCode ? (pending.flatMap { $0 == key ? nil : $0 } ?? make()) : ""
                let failed = step(.failed(key: key, code: code, fresh: fresh, retried: retried))
                if failed.fail { throw error }
                next = failed.send
                retried = true
                continue
            }
            return step(.sent(key)).created
        }
        return false
    }

    private func step(_ event: KeyEvent) -> KeyStep {
        let reply = dockRule("dock.chief_tab_key_step", StepRequest(state: .init(pending: pending), event: event),
                             fallback: KeyStep(state: .init(pending: pending), send: nil, fail: true, created: false))
        pending = reply.state.pending
        return reply
    }

    private nonisolated struct OpenRequest: Encodable {
        var chief: String
        var workspaces: [DockWorkspace]
    }

    private nonisolated struct KeyState: Codable {
        var pending: String?
    }

    private nonisolated enum KeyEvent: Encodable {
        case begin(chiefTabOpen: Bool, fresh: String)
        case sent(String)
        case failed(key: String, code: String?, fresh: String, retried: Bool)
        case settle
        case settleKey(String)

        private enum Keys: String, CodingKey { case type, chiefTabOpen, fresh, key, code, retried }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case let .begin(open, fresh):
                try c.encode("begin", forKey: .type)
                try c.encode(open, forKey: .chiefTabOpen)
                try c.encode(fresh, forKey: .fresh)
            case let .sent(key):
                try c.encode("sent", forKey: .type)
                try c.encode(key, forKey: .key)
            case let .failed(key, code, fresh, retried):
                try c.encode("failed", forKey: .type)
                try c.encode(key, forKey: .key)
                try c.encodeIfPresent(code, forKey: .code)
                try c.encode(fresh, forKey: .fresh)
                try c.encode(retried, forKey: .retried)
            case .settle:
                try c.encode("settle", forKey: .type)
            case let .settleKey(key):
                try c.encode("settleKey", forKey: .type)
                try c.encode(key, forKey: .key)
            }
        }
    }

    private nonisolated struct StepRequest: Encodable {
        var state: KeyState
        var event: KeyEvent
    }

    private nonisolated struct KeyStep: Decodable {
        var state: KeyState
        var send: String?
        var fail: Bool
        var created: Bool
    }
}
