public import Foundation

/// The `project.get_state` snapshot (the legacy `v2ProjectGetState`
/// dictionary, fully typed).
public struct ControlProjectStateSnapshot: Sendable, Equatable {
    /// The load-state portion of the snapshot.
    public enum LoadState: Sendable, Equatable {
        /// The project has not started loading.
        case idle
        /// The project is loading.
        case loading
        /// Loading failed. Carries the failure reason.
        case failed(reason: String)
        /// The project loaded. Carries the module count and the first
        /// module's summary, if any.
        case loaded(moduleCount: Int, module: Module?)
    }

    /// The first module's summary for a loaded project.
    public struct Module: Sendable, Equatable {
        /// The module's display name.
        public let name: String
        /// The module's target count.
        public let targetCount: Int
        /// The module's target display names.
        public let targetNames: [String]
        /// The module's scheme count.
        public let schemeCount: Int
        /// The module's scheme names.
        public let schemeNames: [String]
        /// The module's configuration names.
        public let configurationNames: [String]
        /// The root group's child count.
        public let rootGroupChildren: Int

        /// Creates a module summary.
        ///
        /// - Parameters:
        ///   - name: The display name.
        ///   - targetCount: The target count.
        ///   - targetNames: The target display names.
        ///   - schemeCount: The scheme count.
        ///   - schemeNames: The scheme names.
        ///   - configurationNames: The configuration names.
        ///   - rootGroupChildren: The root group's child count.
        public init(
            name: String,
            targetCount: Int,
            targetNames: [String],
            schemeCount: Int,
            schemeNames: [String],
            configurationNames: [String],
            rootGroupChildren: Int
        ) {
            self.name = name
            self.targetCount = targetCount
            self.targetNames = targetNames
            self.schemeCount = schemeCount
            self.schemeNames = schemeNames
            self.configurationNames = configurationNames
            self.rootGroupChildren = rootGroupChildren
        }
    }

    /// The project panel's identifier.
    public let surfaceID: UUID
    /// The project URL's filesystem path.
    public let projectURLPath: String
    /// The active tab's raw value.
    public let activeTabRawValue: String
    /// The selected scheme name (`""` when none).
    public let selectedScheme: String
    /// The selected configuration name (`""` when none).
    public let selectedConfiguration: String
    /// The selected target identifier (`""` when none).
    public let selectedTargetID: String
    /// The selected file path (`""` when none).
    public let selectedFile: String
    /// The build-settings filter text.
    public let settingsFilter: String
    /// The panel's load state.
    public let loadState: LoadState

    /// Creates a project-state snapshot.
    ///
    /// - Parameters:
    ///   - surfaceID: The project panel's identifier.
    ///   - projectURLPath: The project URL's path.
    ///   - activeTabRawValue: The active tab's raw value.
    ///   - selectedScheme: The selected scheme name.
    ///   - selectedConfiguration: The selected configuration name.
    ///   - selectedTargetID: The selected target identifier.
    ///   - selectedFile: The selected file path.
    ///   - settingsFilter: The settings filter text.
    ///   - loadState: The load state.
    public init(
        surfaceID: UUID,
        projectURLPath: String,
        activeTabRawValue: String,
        selectedScheme: String,
        selectedConfiguration: String,
        selectedTargetID: String,
        selectedFile: String,
        settingsFilter: String,
        loadState: LoadState
    ) {
        self.surfaceID = surfaceID
        self.projectURLPath = projectURLPath
        self.activeTabRawValue = activeTabRawValue
        self.selectedScheme = selectedScheme
        self.selectedConfiguration = selectedConfiguration
        self.selectedTargetID = selectedTargetID
        self.selectedFile = selectedFile
        self.settingsFilter = settingsFilter
        self.loadState = loadState
    }
}
