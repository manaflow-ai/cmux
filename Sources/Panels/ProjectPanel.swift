import AppKit
import CMUXProjectModel
import Combine
import Foundation
import SwiftUI

/// Which tab is active inside a ``ProjectPanel``.
public enum ProjectPanelTab: String, Sendable, Hashable, CaseIterable {
    case files
    case targets
    case buildSettings
    case schemes

    var displayLabel: String {
        switch self {
        case .files: return "Files"
        case .targets: return "Targets"
        case .buildSettings: return "Build Settings"
        case .schemes: return "Schemes"
        }
    }
}

/// Loading state of the parsed ``ProjectModel`` for a ``ProjectPanel``.
public enum ProjectPanelLoadState: Sendable, Equatable {
    case idle
    case loading
    case loaded(ProjectModel)
    case failed(String)

    public var model: ProjectModel? {
        if case let .loaded(model) = self { return model }
        return nil
    }

    public static func == (lhs: ProjectPanelLoadState, rhs: ProjectPanelLoadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading):
            return true
        case let (.loaded(a), .loaded(b)):
            return a == b
        case let (.failed(a), .failed(b)):
            return a == b
        default:
            return false
        }
    }
}

/// Runtime backing for one `project` surface.
///
/// Holds the user's project URL, the parsed ``ProjectModel`` snapshot (loaded
/// off the main actor through ``XcodeProjectAdapter``), and the
/// currently-selected tab / scheme / configuration / node. Panel selection
/// state is plain SwiftUI ``Published`` properties so the view layer can
/// re-render without dealing with reload events.
@MainActor
public final class ProjectPanel: NSObject, Panel, ObservableObject {
    public let id = UUID()
    public let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    public let panelType: PanelType = .project

    @Published public private(set) var projectURL: URL
    @Published public private(set) var loadState: ProjectPanelLoadState = .idle
    @Published public var activeTab: ProjectPanelTab = .files
    @Published public var selectedFilePath: String?
    @Published public var selectedTargetID: TargetID?
    @Published public var selectedSchemeName: String?
    @Published public var selectedConfigurationName: String?
    @Published public var settingsSearchText: String = ""
    @Published public var settingsCustomizedOnly: Bool = false
    @Published public var collapsedNodeIDs: Set<ProjectNodeID> = []
    @Published public var filesSearchText: String = ""
    @Published public var lastLoadError: String?
    private var reloadTask: Task<Void, Never>?

    public var displayTitle: String {
        projectURL.deletingPathExtension().lastPathComponent
    }

    public var displayIcon: String? { "hammer" }

    public init(projectURL: URL) {
        self.projectURL = projectURL
        super.init()
    }

    /// Trigger a load (or reload) of the project model. Safe to call
    /// repeatedly. Loading runs off the main actor. Concurrent calls cancel
    /// any in-flight reload so the latest invocation's result always wins.
    public func reload() {
        reloadTask?.cancel()
        let previousModel = loadState.model
        loadState = .loading
        let url = projectURL
        reloadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let adapter = XcodeProjectAdapter()
            do {
                let model = try adapter.load(at: url)
                if Task.isCancelled { return }
                await self?.applyLoaded(model)
            } catch {
                if Task.isCancelled { return }
                await self?.applyLoadError(error, previousModel: previousModel)
            }
        }
    }

    private func applyLoadError(_ error: Error, previousModel: ProjectModel?) {
        lastLoadError = Self.describe(error)
        if let previousModel {
            loadState = .loaded(previousModel)
        } else {
            loadState = .failed(lastLoadError ?? "Unknown error")
        }
    }

    private func applyLoaded(_ model: ProjectModel) {
        loadState = .loaded(model)
        lastLoadError = nil

        let allSchemeNames = Set(model.modules.flatMap { $0.schemes.map(\.name) })
        if let current = selectedSchemeName, !allSchemeNames.contains(current) {
            selectedSchemeName = nil
        }
        if selectedSchemeName == nil,
           let firstScheme = model.modules.first?.schemes.first?.name {
            selectedSchemeName = firstScheme
        }

        let allConfigNames = Set(model.modules.flatMap { $0.configurationNames })
        if let current = selectedConfigurationName, !allConfigNames.contains(current) {
            selectedConfigurationName = nil
        }
        if selectedConfigurationName == nil,
           let firstConfigName = model.modules.first?.configurationNames.first {
            selectedConfigurationName = firstConfigName
        }

        let allTargetIDs = Set(model.modules.flatMap { $0.targets.map(\.id) })
        if let current = selectedTargetID, !allTargetIDs.contains(current) {
            selectedTargetID = nil
        }
        if selectedTargetID == nil,
           let firstTargetID = model.modules.first?.targets.first?.id {
            selectedTargetID = firstTargetID
        }

        if let path = selectedFilePath,
           !ProjectPanel.fileExistsInModel(path: path, model: model) {
            selectedFilePath = nil
        }

        seedDefaultExpansion(for: model)
    }

    private static func fileExistsInModel(path: String, model: ProjectModel) -> Bool {
        for module in model.modules {
            if pathExists(in: module.rootGroup, path: path) { return true }
        }
        return false
    }

    private static func pathExists(in group: ProjectGroup, path: String) -> Bool {
        for child in group.children {
            switch child {
            case let .file(file):
                if file.resolvedPath?.path == path { return true }
            case let .group(subgroup):
                if pathExists(in: subgroup, path: path) { return true }
            }
        }
        return false
    }

    private func seedDefaultExpansion(for model: ProjectModel) {
        guard collapsedNodeIDs.isEmpty else { return }
        var collapsed: Set<ProjectNodeID> = []
        for module in model.modules {
            collapseDeepNodes(
                in: module.rootGroup,
                depth: 0,
                maxOpenDepth: 1,
                accumulator: &collapsed
            )
        }
        collapsedNodeIDs = collapsed
    }

    private func collapseDeepNodes(
        in group: ProjectGroup,
        depth: Int,
        maxOpenDepth: Int,
        accumulator: inout Set<ProjectNodeID>
    ) {
        if depth > maxOpenDepth {
            accumulator.insert(group.id)
        }
        for child in group.children {
            if case let .group(subgroup) = child {
                collapseDeepNodes(
                    in: subgroup,
                    depth: depth + 1,
                    maxOpenDepth: maxOpenDepth,
                    accumulator: &accumulator
                )
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let load = error as? ProjectLoadError {
            switch load {
            case let .unreadable(url):
                return "Cannot read \(url.path)"
            case let .unsupported(url):
                return "Unsupported project at \(url.path)"
            case let .parseFailure(url, reason):
                return "Parse failed at \(url.path): \(reason)"
            }
        }
        return String(describing: error)
    }

    // MARK: Panel protocol

    public func close() {}
    public func focus() { triggerFlash(reason: .navigation) }
    public func unfocus() {}

    public func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }

    public func captureFocusIntent(in window: NSWindow?) -> PanelFocusIntent {
        _ = window
        return .project(.navigator)
    }

    public func preferredFocusIntentForActivation() -> PanelFocusIntent {
        .project(.navigator)
    }

    public func prepareFocusIntentForActivation(_ intent: PanelFocusIntent) {
        _ = intent
    }

    @discardableResult
    public func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool {
        if case .project = intent { return true }
        return false
    }

    public func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        _ = responder
        _ = window
        return nil
    }

    @discardableResult
    public func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool {
        _ = intent
        _ = window
        return false
    }
}
