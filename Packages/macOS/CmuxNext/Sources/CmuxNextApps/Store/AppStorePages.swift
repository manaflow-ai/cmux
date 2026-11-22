public import AppKit

/// The App Store tabs (internal page `app-store`): one store model per tab
/// over one shared registry and host, so each tab keeps its own search,
/// tab and selection. The App's page provider forwards to this.
@MainActor
public final class AppStorePages {
    private let makeModel: () -> AppStoreModel
    private var models: [String: AppStoreModel] = [:]

    /// - Parameter makeModel: a new store model (the owner shares its registry and host).
    public init(makeModel: @escaping () -> AppStoreModel) {
        self.makeModel = makeModel
    }

    /// The view of tab `key`, created once per tab; never opens a window.
    public func makeView(for key: String) -> NSView {
        let model = models[key] ?? makeModel()
        models[key] = model
        model.refresh()
        return model.makeContentView(inPane: true)
    }

    public func model(for key: String) -> AppStoreModel? { models[key] }

    /// Shows a listing or the Installed tab in tab `key`.
    public func present(_ key: String, appID: String?, installed: Bool) {
        models[key]?.present(appID: appID, installed: installed)
    }

    /// Re-reads the catalog in every tab (after the registry scan).
    public func refreshAll() {
        for model in models.values { model.refresh() }
    }

    /// Drops tab `key`'s model. A Remove still in its undo window commits: the closed tab has no
    /// Undo to show, and the user asked for a remove (the task keeps the model until it ends).
    public func tabClosed(_ key: String) {
        guard let model = models.removeValue(forKey: key), model.pendingRemoval != nil else { return }
        // task-owner: one commit of the closed tab's pending Remove; ends when the registry write does
        Task { await model.commitPendingRemoval() }
    }
}
