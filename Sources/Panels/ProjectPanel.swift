import AppKit
import CMUXProjectModel
import Combine
import Foundation
import OSLog
import SwiftUI

private let projectPanelLogger = Logger(subsystem: "com.cmuxterm.app", category: "ProjectPanel")

/// Localized presentation for values that are shared by the project panel's
/// tabs. Parser errors intentionally expose only a stable, localized summary;
/// the adapter's raw reason is logged by ``ProjectPanel`` for diagnostics.
enum ProjectPanelLocalization {
    static func loadErrorMessage(for error: Error, projectURL: URL) -> String {
        if let loadError = error as? ProjectLoadError {
            switch loadError {
            case let .unreadable(url):
                return String.localizedStringWithFormat(
                    String(localized: "projectPanel.loadError.unreadable", defaultValue: "Cannot read project at %@"),
                    url.path
                )
            case let .unsupported(url):
                return String.localizedStringWithFormat(
                    String(localized: "projectPanel.loadError.unsupported", defaultValue: "Unsupported project at %@"),
                    url.path
                )
            case let .parseFailure(url, _):
                return String.localizedStringWithFormat(
                    String(localized: "projectPanel.loadError.parseFailure", defaultValue: "Unable to parse project at %@"),
                    url.path
                )
            }
        }
        return String.localizedStringWithFormat(
            String(localized: "projectPanel.loadError.generic", defaultValue: "Unable to load project at %@"),
            projectURL.path
        )
    }

    static func productTypeLabel(_ productType: TargetProductType) -> String {
        switch productType {
        case .application:
            return String(localized: "projectTargets.productType.application", defaultValue: "Application")
        case .framework:
            return String(localized: "projectTargets.productType.framework", defaultValue: "Framework")
        case .staticLibrary:
            return String(localized: "projectTargets.productType.staticLibrary", defaultValue: "Static library")
        case .dynamicLibrary:
            return String(localized: "projectTargets.productType.dynamicLibrary", defaultValue: "Dynamic library")
        case .bundle:
            return String(localized: "projectTargets.productType.bundle", defaultValue: "Bundle")
        case .unitTest:
            return String(localized: "projectTargets.productType.unitTest", defaultValue: "Unit test")
        case .uiTest:
            return String(localized: "projectTargets.productType.uiTest", defaultValue: "UI test")
        case .commandLineTool:
            return String(localized: "projectTargets.productType.commandLineTool", defaultValue: "Command-line tool")
        case .appExtension:
            return String(localized: "projectTargets.productType.appExtension", defaultValue: "App extension")
        case .watchApp:
            return String(localized: "projectTargets.productType.watchApp", defaultValue: "Watch app")
        case .watchExtension:
            return String(localized: "projectTargets.productType.watchExtension", defaultValue: "Watch extension")
        case .xcFramework:
            return String(localized: "projectTargets.productType.xcFramework", defaultValue: "XCFramework")
        case .other:
            return String(localized: "projectTargets.productType.other", defaultValue: "Other")
        }
    }

    static func membershipRoleLabel(_ role: TargetMembershipRole) -> String {
        switch role {
        case .compile:
            return String(localized: "projectFiles.membership.role.compile", defaultValue: "Compile")
        case .resource:
            return String(localized: "projectFiles.membership.role.resource", defaultValue: "Resource")
        case .copy:
            return String(localized: "projectFiles.membership.role.copy", defaultValue: "Copy")
        case .framework:
            return String(localized: "projectFiles.membership.role.framework", defaultValue: "Framework")
        case .header:
            return String(localized: "projectFiles.membership.role.header", defaultValue: "Header")
        case .script:
            return String(localized: "projectFiles.membership.role.script", defaultValue: "Script")
        }
    }
}

/// Which tab is active inside a ``ProjectPanel``.
public enum ProjectPanelTab: String, Sendable, Hashable, CaseIterable {
    case files
    case targets
    case buildSettings
    case schemes

    var displayLabel: String {
        switch self {
        case .files:
            return String(localized: "projectPanel.tab.files", defaultValue: "Files")
        case .targets:
            return String(localized: "projectPanel.tab.targets", defaultValue: "Targets")
        case .buildSettings:
            return String(localized: "projectPanel.tab.buildSettings", defaultValue: "Build Settings")
        case .schemes:
            return String(localized: "projectPanel.tab.schemes", defaultValue: "Schemes")
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
        projectPanelLogger.error(
            "Project load failed at \(projectURL.path, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash))"
        )
        lastLoadError = ProjectPanelLocalization.loadErrorMessage(for: error, projectURL: projectURL)
        if let previousModel {
            loadState = .loaded(previousModel)
        } else {
            loadState = .failed(lastLoadError ?? String.localizedStringWithFormat(
                String(localized: "projectPanel.loadError.generic", defaultValue: "Unable to load project at %@"),
                projectURL.path
            ))
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
