internal import Foundation

/// The daemon-owned structural topology shared by every frontend presentation.
public struct CanonicalTopology: Codable, Equatable, Sendable {
    /// Maximum workspaces accepted from one backend snapshot.
    public static let maximumWorkspaces = 4_096

    /// Maximum screens accepted within one workspace.
    public static let maximumScreensPerWorkspace = 4_096

    /// Maximum panes accepted within one screen.
    public static let maximumPanesPerScreen = 4_096

    /// Maximum surfaces accepted within one pane.
    public static let maximumSurfacesPerPane = 4_096

    /// Maximum combined workspaces, screens, panes, and surfaces.
    public static let maximumTotalEntities = 100_000

    /// The canonical workspaces in backend order.
    public let workspaces: [CanonicalWorkspace]

    /// Creates and validates canonical topology.
    ///
    /// - Parameter workspaces: The canonical workspaces in backend order.
    /// - Throws: ``CanonicalTopologyError`` when the topology violates an invariant.
    public init(workspaces: [CanonicalWorkspace]) throws {
        self.workspaces = workspaces
        try validate()
    }

    /// Decodes and validates canonical topology.
    ///
    /// - Parameter decoder: The decoder containing the canonical topology.
    /// - Throws: A decoding error or ``CanonicalTopologyError`` for invalid structure.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try container.decode([CanonicalWorkspace].self, forKey: .workspaces)
        try validate()
    }

    /// Verifies identity uniqueness, nonempty containment, and exact layout references.
    ///
    /// - Throws: ``CanonicalTopologyError`` when any structural invariant is violated.
    public func validate() throws {
        guard workspaces.count <= Self.maximumWorkspaces else {
            throw CanonicalTopologyError.budgetExceeded(
                "workspace count exceeds \(Self.maximumWorkspaces)"
            )
        }
        var allUUIDs: Set<UUID> = []
        var workspaceNumbers: Set<UInt64> = []
        var screenNumbers: Set<UInt64> = []
        var paneNumbers: Set<UInt64> = []
        var surfaceNumbers: Set<UInt64> = []
        var totalEntities = 0

        func account(_ count: Int, _ label: String) throws {
            let (next, overflow) = totalEntities.addingReportingOverflow(count)
            guard !overflow, next <= Self.maximumTotalEntities else {
                throw CanonicalTopologyError.budgetExceeded(
                    "\(label) exceeds total entity budget \(Self.maximumTotalEntities)"
                )
            }
            totalEntities = next
        }

        try account(workspaces.count, "workspaces")

        for workspace in workspaces {
            guard workspace.screens.count <= Self.maximumScreensPerWorkspace else {
                throw CanonicalTopologyError.budgetExceeded(
                    "screens per workspace exceed \(Self.maximumScreensPerWorkspace)"
                )
            }
            try account(workspace.screens.count, "screens")
            try insert(workspace.uuid.rawValue, into: &allUUIDs)
            try insert(workspace.id, into: &workspaceNumbers)
            guard !workspace.screens.isEmpty else {
                throw CanonicalTopologyError.invalidReference("workspace without screens")
            }

            for screen in workspace.screens {
                guard screen.panes.count <= Self.maximumPanesPerScreen else {
                    throw CanonicalTopologyError.budgetExceeded(
                        "panes per screen exceed \(Self.maximumPanesPerScreen)"
                    )
                }
                try account(screen.panes.count, "panes")
                try insert(screen.uuid.rawValue, into: &allUUIDs)
                try insert(screen.id, into: &screenNumbers)
                var panesByNumber: [UInt64: CanonicalPane] = [:]
                for pane in screen.panes {
                    guard pane.tabs.count <= Self.maximumSurfacesPerPane else {
                        throw CanonicalTopologyError.budgetExceeded(
                            "surfaces per pane exceed \(Self.maximumSurfacesPerPane)"
                        )
                    }
                    try account(pane.tabs.count, "surfaces")
                    try insert(pane.uuid.rawValue, into: &allUUIDs)
                    try insert(pane.id, into: &paneNumbers)
                    panesByNumber[pane.id] = pane
                    guard !pane.tabs.isEmpty else {
                        throw CanonicalTopologyError.invalidReference("pane without surfaces")
                    }
                    for surface in pane.tabs {
                        try insert(surface.uuid.rawValue, into: &allUUIDs)
                        try insert(surface.id, into: &surfaceNumbers)
                    }
                }
                guard !panesByNumber.isEmpty else {
                    throw CanonicalTopologyError.invalidReference("screen without panes")
                }

                var layoutPanes: Set<PaneID> = []
                try screen.layout.collectPaneIDs(into: &layoutPanes, panesByNumber: panesByNumber)
                guard layoutPanes == Set(screen.panes.map(\.uuid)) else {
                    throw CanonicalTopologyError.invalidReference("layout pane set")
                }
            }
        }
    }

    private func insert(_ value: UUID, into values: inout Set<UUID>) throws {
        guard values.insert(value).inserted else {
            throw CanonicalTopologyError.duplicateIdentity(value)
        }
    }

    private func insert(_ value: UInt64, into values: inout Set<UInt64>) throws {
        guard values.insert(value).inserted else {
            throw CanonicalTopologyError.duplicateNumericID(value)
        }
    }
}
