import CmuxNextDaemon
import Foundation

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
final class HomeChiefTabKey {
    /// The daemon's refusal of a key whose tab was closed.
    static let keyClosedCode = "frontend_browser_key_closed"

    private var pending: String?
    private let make: @Sendable () -> String

    init(make: @escaping @Sendable () -> String = { "home-chief-tab-\(UUID().uuidString.lowercased())" }) {
        self.make = make
    }

    /// Whether a conversation tab shows `chief` in any of `workspaces`: the
    /// person may move the chief tab out of the home, and a moved tab still
    /// counts (a second chief tab is never created).
    static func isOpen(chief: String, in workspaces: [WorkspaceModel]) -> Bool {
        workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
            .contains { $0.kind == .conversation && $0.snapshot.conversation?.conversation == chief }
    }

    /// The key of the next creation: the pending one, else a new one.
    func forCreate() -> String {
        if let pending { return pending }
        let key = make()
        pending = key
        return key
    }

    /// The chief tab is present: the next creation takes a new key.
    func settle() { pending = nil }

    /// `key`'s creation ended (the tab exists, or the store refused the key
    /// because its tab closed). A newer pending key stays.
    func settle(_ key: String) {
        if pending == key { pending = nil }
    }

    /// One connect: nothing while the chief tab is open; else one keyed
    /// create through `send`. A `frontend_browser_key_closed` refusal (the
    /// pending key's tab was created and closed) is not shown: it retries once
    /// with a new key. Any other failure keeps the key pending. Returns
    /// whether it sent a create.
    func ensure(chiefTabOpen: Bool, send: (String) async throws -> Void) async throws -> Bool {
        if chiefTabOpen {
            settle()
            return false
        }
        var key = forCreate()
        do {
            try await send(key)
        } catch let DaemonError.command(_, _, code, _, _) where code == Self.keyClosedCode {
            settle(key)
            key = forCreate()
            try await send(key)
        }
        settle(key)
        return true
    }
}
