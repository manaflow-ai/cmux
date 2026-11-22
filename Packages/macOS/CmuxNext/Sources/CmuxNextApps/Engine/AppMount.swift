public import Foundation

/// One mounted contribution (a sidebar section, a status item, a store
/// preview): its scene model, and the engine its UI events go to.
@MainActor
public final class AppMount: AppSceneInteraction, Identifiable {
    public let id: String
    public let appID: String
    public let contribution: AppContribution
    public let bundleDirectory: URL
    public let model: AppSceneModel
    weak var host: AppHost?

    init(id: String, appID: String, contribution: AppContribution, bundleDirectory: URL, host: AppHost) {
        self.id = id
        self.appID = appID
        self.contribution = contribution
        self.bundleDirectory = bundleDirectory
        self.host = host
        model = AppSceneModel()
        model.interaction = self
    }

    public func dispatch(node: String, event: String, payload: AppJSON) {
        guard let engine = host?.engines[appID] else { return }
        let mount = id
        // task-owner: one UI event, ordered on the engine's executor
        Task { await engine.dispatch(mount, node: node, event: event, payload: payload) }
    }

    /// A fresh `AppSceneHostingView` for AppKit hosts (the sidebar).
    public func makeView() -> AppSceneHostingView { AppSceneHostingView(model: model, bundleDirectory: bundleDirectory) }
}

/// One line of an app's log (`cmux.log`, runtime errors, engine stops).
public nonisolated struct AppLogLine: Sendable, Hashable, Identifiable {
    public var id: Int
    public var date: Date
    public var level: String
    public var message: String
}
