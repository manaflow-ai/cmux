public import Foundation

/// What one classic migration run makes, worked out before anything is made.
public nonisolated struct ClassicMigrationPlan: Equatable, Sendable {
    /// One classic window's workspaces that come over in this run, in sidebar order.
    public nonisolated struct Window: Equatable, Sendable {
        public var frame: CGRect?
        /// The key of the workspace classic had selected, when it comes over in this run.
        public var selectedKey: String?
        public var workspaces: [ClassicSessionWorkspace]

        public init(frame: CGRect? = nil, selectedKey: String? = nil, workspaces: [ClassicSessionWorkspace]) {
            self.frame = frame
            self.selectedKey = selectedKey
            self.workspaces = workspaces
        }
    }

    /// A classic group the run needs: one to make, or one an earlier run made.
    public nonisolated struct Group: Equatable, Sendable {
        public var classic: ClassicSessionGroup
        /// The cmux-next group an earlier run made for it and that still exists; nil makes one.
        public var existing: String?

        public init(classic: ClassicSessionGroup, existing: String? = nil) {
            self.classic = classic
            self.existing = existing
        }
    }

    /// Why a classic workspace does not come over in this run.
    public nonisolated enum Skip: String, Equatable, Sendable {
        /// An earlier run brought it over (and, for a manual run, it is still open).
        case alreadyMigrated
        /// The snapshot names its key twice; the first one comes over.
        case duplicate
        /// A Cloud VM workspace: cmux-next cannot attach a classic VM.
        case cloudVM
    }

    public var windows: [Window]
    public var groups: [Group]
    /// cmux-next workspaces a cut-off run left half made: closed before they are made again.
    public var cleanup: [String]
    public var skipped: [String: Skip]

    public init(windows: [Window] = [], groups: [Group] = [], cleanup: [String] = [], skipped: [String: Skip] = [:]) {
        self.windows = windows
        self.groups = groups
        self.cleanup = cleanup
        self.skipped = skipped
    }

    /// Every workspace that comes over, window after window.
    public var workspaces: [ClassicSessionWorkspace] { windows.flatMap(\.workspaces) }

    /// Whether the run has nothing to make.
    public var isEmpty: Bool { windows.isEmpty && groups.allSatisfy { $0.existing != nil } && cleanup.isEmpty }
}
