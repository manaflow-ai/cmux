public import CmuxNextDaemon
import CmuxNextHomeEngine
import Foundation

/// Which conversation Home's Chief tab shows and how the tab moves: the main
/// conversation of the signed-in user's cloud Chief (the Hosted Chief by
/// default, or "Chief (Mac mini)" when the user switched to it), else the
/// local conversation with the local mux.
extension HomeCloudChiefs {
    /// One POST to the API Worker as the signed-in user (`v1/read`, `v1/ops`); a refusal throws ``HostedChiefError``.
    public typealias Call = @MainActor (_ path: String, _ body: [String: Any]) async throws -> [String: Any]

    /// The Chief tab's conversation: the shown cloud Chief's main conversation, else `local`.
    /// One history: with a Hosted Chief the local Chief's history is copied
    /// into its main conversation (``HostedChiefMigration``), so a cloud
    /// Chief takes the tab also when the local Chief has history. Without
    /// one (a service with no Cloud Chief brains), a placed chief takes the
    /// tab only when the local Chief has no history to hide. `prefersLocal`
    /// (the default Chief is this Mac's, `HomeChiefDefault`) gives the tab to `local`, and never
    /// to a cloud Chief: while this Mac's conversation is not listed yet the tab waits (nil) rather
    /// than open the cloud composer the person's choice sends nothing to. `ensureChiefTab` waits
    /// for the Chief owner and looks the conversation up in that case, so the tab arrives.
    public func chiefTab(local: String?, localHasHistory: Bool, choice: HomeChiefChoice, prefersLocal: Bool = false) -> String? {
        if prefersLocal { return local }
        if hosted == nil, let local, localHasHistory { return local }
        return shown(choice: choice)?.mainConversation ?? local
    }

    /// The Chief moved to `chief` (a cloud Chief) from one of `from` (the
    /// local Chief, or the other cloud Chief after a switch): the tabs that
    /// still show one of them close, and the Chief opens in the first one's
    /// pane, so Home keeps one Chief tab. Nothing moves while the Chief is
    /// local or it already has its tab.
    public static func move(from: [String], chief: String, in workspaces: [WorkspaceModel]) -> (close: [SurfaceID], pane: PaneID?) {
        let from = Set(from.filter { $0 != chief })
        guard !from.isEmpty, !HomeChiefTabKey.isOpen(chief: chief, in: workspaces) else { return ([], nil) }
        var close: [SurfaceID] = []
        var pane: PaneID?
        for candidate in workspaces.flatMap(\.screens).flatMap(\.panes) {
            for tab in candidate.tabs where tab.kind == .conversation && tab.snapshot.conversation?.conversation.map(from.contains) == true {
                close.append(tab.surface)
                pane = pane ?? candidate.handle
            }
        }
        return (close, pane)
    }

    /// The tabs that show another cloud Chief's conversation (`stale`)
    /// while the Chief is `chief`: a switch or a relaunch gives the tab back.
    public static func staleChiefTabs(stale: [String], chief: String, in workspaces: [WorkspaceModel]) -> [SurfaceID] {
        let stale = Set(stale.filter { $0 != chief })
        guard !stale.isEmpty else { return [] }
        return workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
            .filter { $0.kind == .conversation && $0.snapshot.conversation?.conversation.map(stale.contains) == true }
            .map(\.surface)
    }

    /// The user's cloud Chiefs, with a Hosted Chief made when this service
    /// runs Cloud Chief brains (`hostedBrains`); without them only the
    /// placed chief is read (Home then keeps the local chief when none is
    /// placed). A failure is logged by the caller, never shown.
    public static func read(call: Call, hostedBrains: Bool) async throws -> HomeCloudChiefs {
        if hostedBrains { return try await ensureHosted(call: call) }
        let found = placed(in: try await list(call: call))
        return HomeCloudChiefs(hosted: nil, placed: found?.mainConversation == nil ? nil : found)
    }

    /// The active chiefs (`chief.list`; archived ones are never listed by default).
    public static func list(call: Call) async throws -> [CloudChief] {
        let value = try okValue(try await call("v1/read", ["op": "chief.list", "params": [String: Any]()])) as? [String: Any]
        return (value?["chiefs"] as? [Any] ?? []).compactMap(CloudChief.parse)
    }

    /// The chief whose brain runs on a server: the default one when it is
    /// placed, else the first placed one; nil when no chief is placed.
    public static func placed(in chiefs: [CloudChief]) -> CloudChief? {
        let placed = chiefs.filter { $0.brainPlace != nil }
        return placed.first(where: \.isDefault) ?? placed.first
    }

    /// Makes sure the user has a Hosted Chief and that it is the default:
    /// `chief.create` under a fixed key when none exists. A placed chief
    /// still named plain "Chief" becomes "Chief (Mac mini)". No chief's
    /// `brain_place` changes. One revision conflict re-reads once.
    static func ensureHosted(call: Call) async throws -> HomeCloudChiefs {
        func op(_ name: String, _ key: String, _ params: [String: Any]) async throws -> Any? {
            try okValue(try await call("v1/ops", ["op": name, "origin": "user", "idempotency_key": key, "params": params]))
        }
        for attempt in 0..<2 {
            var chiefs = try await list(call: call)
            do {
                // The fixed key makes one Hosted Chief across devices; when it replays a chief that
                // is now placed or archived (not in the list as hosted), a fresh key makes a new one.
                for key in ["chief-hosted-default", "chief-hosted-\(UUID().uuidString.lowercased())"] where hosted(in: chiefs) == nil {
                    // Only a chief this Mac's create made gets its brain turned on; a replay is a chief that may be
                    // off on purpose, unless it replays this Mac's own earlier create whose reply never came back.
                    let sentBefore = createdHere("key:\(key)")
                    createdHere("key:\(key)", true)
                    let reply = try await call("v1/ops", ["op": "chief.create", "origin": "user", "idempotency_key": key,
                                                          "params": ["display_name": HomeStrings.chiefName, "is_default": true]])
                    guard let created = CloudChief.parse(try okValue(reply)) else { throw HostedChiefError.badReply }
                    if reply["replayed"] as? Bool != true || sentBefore { createdHere(created.id, true) }
                    createdHere("key:\(key)", false)
                    chiefs = try await list(call: call)
                }
                if let mini = placed(in: chiefs), [HomeStrings.chiefName, "Chief", ""].contains(mini.displayName) {
                    _ = try await op("chief.update", "chief-placed-rename-\(mini.id)-\(mini.rev)",
                                     ["chief": mini.id, "expected_rev": mini.rev, "display_name": placedName])
                    chiefs = try await list(call: call)
                }
                if let chief = hosted(in: chiefs), !chief.isDefault {
                    _ = try await op("chief.update", "chief-hosted-default-\(chief.id)-\(chief.rev)",
                                     ["chief": chief.id, "expected_rev": chief.rev, "is_default": true])
                    chiefs = try await list(call: call)
                }
                return HomeCloudChiefs(hosted: hosted(in: chiefs), placed: placed(in: chiefs))
            } catch HostedChiefError.owner(code: "revision.conflict", message: _) where attempt == 0 {
                continue
            }
        }
        throw HostedChiefError.owner(code: "revision.conflict", message: "the chief changed on another device; try again")
    }

    /// Hosted Chiefs that this Mac's Home created and whose brain it has not
    /// turned on yet (and, as "key:<idempotency key>", creates sent without a
    /// reply yet). Kept across launches: a quit before the enable still turns
    /// it on at the next connect. Never set for a chief that existed.
    static func createdHere(_ chief: String) -> Bool {
        UserDefaults.standard.stringArray(forKey: createdKey)?.contains(chief) == true
    }

    static func createdHere(_ chief: String, _ value: Bool) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: createdKey) ?? [])
        if value { ids.insert(chief) } else { ids.remove(chief) }
        UserDefaults.standard.set(ids.sorted(), forKey: createdKey)
    }

    private static let createdKey = "home.chief.hosted.created"

    /// The ops envelope's value; a refusal (`_tag` and `code`) throws.
    static func okValue(_ reply: [String: Any]) throws -> Any? {
        if reply["_tag"] != nil, let code = reply["code"] as? String { throw HostedChiefError.owner(code: code, message: reply["message"] as? String ?? code) }
        return reply["value"]
    }
}
