/// One App Store catalog entry, as first launch sees it.
public nonisolated struct AppCatalogEntry: Sendable, Hashable {
    public var appID: String
    public var tier: AppTier
    /// In the store's "Samples" category: opt-in, never default-installed.
    public var isSample: Bool

    public init(appID: String, tier: AppTier, isSample: Bool = false) {
        self.appID = appID
        self.tier = tier
        self.isSample = isSample
    }
}

/// First-launch default installs (critique C7 "Defaults"): every
/// first-party app that is not a sample, as `install(.default)` ops from
/// the owner itself. Keys are stable per app, so running it on every
/// launch is idempotent, and a default the user removed stays removed.
public nonisolated enum AppDefaultInstalls {
    public static func ops(catalog: [AppCatalogEntry]) -> [AppStateOp] {
        catalog.filter { $0.tier == .firstParty && !$0.isSample }
            .map { AppStateOp(key: "default-install:\($0.appID)", app: $0.appID, kind: .install(.default)) }
    }

    /// Applies the default installs to `store`.
    public static func bootstrap(_ store: AppStateStore, catalog: [AppCatalogEntry]) -> (AppStateStore, [AppStateEvent]) {
        var store = store
        var events: [AppStateEvent] = []
        for op in ops(catalog: catalog) {
            if case .success(let (next, commit)) = AppStateReducer.apply(op, to: store, actor: .system) {
                store = next
                events += commit.events
            }
        }
        return (store, events)
    }
}
