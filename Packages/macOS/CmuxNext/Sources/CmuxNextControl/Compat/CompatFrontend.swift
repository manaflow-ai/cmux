public import CmuxNextSettings

/// Client-local state the CLI can see (architecture.md 1: windows, which
/// workspace each shows, focus, and tab selection belong to the app, not the
/// daemon). The App publishes a fresh value after every change; ids are the
/// App's model ids (`WindowState.id`, `WorkspaceModel.id` = workspace key,
/// `PaneModel.id`, `TabModel.id`).
public struct CompatFrontendSnapshot: Sendable, Hashable {
    public struct Window: Sendable, Hashable {
        public var id: String
        public var workspaceID: String?
        /// Focused pane of the shown workspace.
        public var focusedPaneID: String?
        /// Selected tab per pane (`PaneModel.id` -> `TabModel.id`).
        public var selectedTabs: [String: String]
        public var isKey: Bool
        public var isVisible: Bool

        public init(id: String, workspaceID: String?, focusedPaneID: String? = nil, selectedTabs: [String: String] = [:],
                    isKey: Bool = false, isVisible: Bool = true) {
            self.id = id
            self.workspaceID = workspaceID
            self.focusedPaneID = focusedPaneID
            self.selectedTabs = selectedTabs
            self.isKey = isKey
            self.isVisible = isVisible
        }
    }

    /// Open windows, in the App's window order.
    public var windows: [Window]
    /// The window CLI commands act on by default (key, else last active).
    public var activeWindowID: String?

    public init(windows: [Window] = [], activeWindowID: String? = nil) {
        self.windows = windows
        self.activeWindowID = activeWindowID
    }
}

/// Implemented by the App. `snapshot()` must not block (read a published
/// value); `perform` runs on the main actor through the App's bounded work
/// path and republishes the snapshot before it returns, so a CLI read that
/// follows a CLI write sees the write.
public protocol CompatFrontend: Sendable {
    func snapshot() -> CompatFrontendSnapshot
    func perform(_ intent: CompatFrontendIntent) async throws -> JSONValue
}

/// Frontend for tests and headless runs: no windows, every intent refused.
public struct HeadlessCompatFrontend: CompatFrontend {
    public init() {}
    public func snapshot() -> CompatFrontendSnapshot { CompatFrontendSnapshot() }
    public func perform(_ intent: CompatFrontendIntent) async throws -> JSONValue {
        throw CompatErrors.unsupported("no app window is available for \(intent)")
    }
}
