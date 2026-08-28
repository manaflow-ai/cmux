public import Foundation

/// Identifies the narrowest workspace, pane, or surface that owns a process.
public struct CmuxTopMemoryOwner: Hashable, Sendable {
    public let workspaceID: UUID?
    public let workspaceRef: String?
    public let paneID: UUID?
    public let paneRef: String?
    public let surfaceID: UUID?
    public let surfaceRef: String?
    public let surfaceType: String?

    /// Creates owner metadata with any available workspace, pane, and surface identifiers.
    public init(
        workspaceID: UUID?,
        workspaceRef: String?,
        paneID: UUID?,
        paneRef: String?,
        surfaceID: UUID?,
        surfaceRef: String?,
        surfaceType: String?
    ) {
        self.workspaceID = workspaceID
        self.workspaceRef = workspaceRef
        self.paneID = paneID
        self.paneRef = paneRef
        self.surfaceID = surfaceID
        self.surfaceRef = surfaceRef
        self.surfaceType = surfaceType
    }

    /// Returns the specificity used to choose a narrow owner over a broad one.
    public var specificity: Int {
        if surfaceID != nil || surfaceRef != nil { return 3 }
        if paneID != nil || paneRef != nil { return 2 }
        if workspaceID != nil || workspaceRef != nil { return 1 }
        return 0
    }

    /// Returns a stable identity key for grouping attributed processes.
    public var identityKey: String? {
        if let surface = Self.identifier(id: surfaceID, ref: surfaceRef) {
            return "surface:\(surface)"
        }
        if let pane = Self.identifier(id: paneID, ref: paneRef) {
            return "pane:\(pane)"
        }
        if let workspace = workspaceIdentityKey {
            return "workspace:\(workspace)"
        }
        return nil
    }

    /// Returns the workspace identity used to count distinct owners.
    public var workspaceIdentityKey: String? {
        Self.identifier(id: workspaceID, ref: workspaceRef)
    }

    /// Finds the narrowest owner shared by two attribution candidates.
    public func commonOwner(with other: CmuxTopMemoryOwner) -> CmuxTopMemoryOwner? {
        guard Self.identifiersMatch(
            lhsID: workspaceID,
            lhsRef: workspaceRef,
            rhsID: other.workspaceID,
            rhsRef: other.workspaceRef
        ) else {
            return nil
        }

        let mergedWorkspaceID = workspaceID ?? other.workspaceID
        let mergedWorkspaceRef = workspaceRef ?? other.workspaceRef
        if Self.identifiersMatch(
            lhsID: surfaceID,
            lhsRef: surfaceRef,
            rhsID: other.surfaceID,
            rhsRef: other.surfaceRef
        ), Self.identifiersAreCompatible(
            lhsID: paneID,
            lhsRef: paneRef,
            rhsID: other.paneID,
            rhsRef: other.paneRef
        ) {
            return CmuxTopMemoryOwner(
                workspaceID: mergedWorkspaceID,
                workspaceRef: mergedWorkspaceRef,
                paneID: paneID ?? other.paneID,
                paneRef: paneRef ?? other.paneRef,
                surfaceID: surfaceID ?? other.surfaceID,
                surfaceRef: surfaceRef ?? other.surfaceRef,
                surfaceType: surfaceType ?? other.surfaceType
            )
        }
        if Self.identifiersMatch(
            lhsID: paneID,
            lhsRef: paneRef,
            rhsID: other.paneID,
            rhsRef: other.paneRef
        ) {
            return CmuxTopMemoryOwner(
                workspaceID: mergedWorkspaceID,
                workspaceRef: mergedWorkspaceRef,
                paneID: paneID ?? other.paneID,
                paneRef: paneRef ?? other.paneRef,
                surfaceID: nil,
                surfaceRef: nil,
                surfaceType: nil
            )
        }
        return CmuxTopMemoryOwner(
            workspaceID: mergedWorkspaceID,
            workspaceRef: mergedWorkspaceRef,
            paneID: nil,
            paneRef: nil,
            surfaceID: nil,
            surfaceRef: nil,
            surfaceType: nil
        )
    }

    /// Chooses the stable identifier when either form is available.
    private static func identifier(id: UUID?, ref: String?) -> String? {
        id?.uuidString ?? ref
    }

    /// Compares two identifiers without treating missing values as equal.
    private static func identifiersMatch(
        lhsID: UUID?,
        lhsRef: String?,
        rhsID: UUID?,
        rhsRef: String?
    ) -> Bool {
        if let lhsID, let rhsID { return lhsID == rhsID }
        if let lhsRef, let rhsRef { return lhsRef == rhsRef }
        return false
    }

    /// Checks whether partial owner metadata can be merged safely.
    private static func identifiersAreCompatible(
        lhsID: UUID?,
        lhsRef: String?,
        rhsID: UUID?,
        rhsRef: String?
    ) -> Bool {
        let lhsExists = lhsID != nil || lhsRef != nil
        let rhsExists = rhsID != nil || rhsRef != nil
        guard lhsExists, rhsExists else { return true }
        return identifiersMatch(
            lhsID: lhsID,
            lhsRef: lhsRef,
            rhsID: rhsID,
            rhsRef: rhsRef
        )
    }
}

/// Records an owner together with the evidence used to infer it.
public struct CmuxTopMemoryAttribution: Hashable, Sendable {
    public let workspaceID: UUID?
    public let workspaceRef: String?
    public let paneID: UUID?
    public let paneRef: String?
    public let surfaceID: UUID?
    public let surfaceRef: String?
    public let surfaceType: String?
    public let reason: String

    /// Creates an attribution value from an owner and evidence label.
    public init(owner: CmuxTopMemoryOwner, reason: String) {
        self.workspaceID = owner.workspaceID
        self.workspaceRef = owner.workspaceRef
        self.paneID = owner.paneID
        self.paneRef = owner.paneRef
        self.surfaceID = owner.surfaceID
        self.surfaceRef = owner.surfaceRef
        self.surfaceType = owner.surfaceType
        self.reason = reason
    }

    /// Reconstructs the structured owner represented by this attribution.
    public var owner: CmuxTopMemoryOwner {
        CmuxTopMemoryOwner(
            workspaceID: workspaceID,
            workspaceRef: workspaceRef,
            paneID: paneID,
            paneRef: paneRef,
            surfaceID: surfaceID,
            surfaceRef: surfaceRef,
            surfaceType: surfaceType
        )
    }
}

/// One already-annotated node supplied to the attribution reducer.
public struct CmuxTopMemoryAttributionNode: Sendable {
    public let owner: CmuxTopMemoryOwner
    public let defaultReason: String
    public let processIDs: [Int]
    public let processReasons: [Int: String]

    /// Creates one reducer input node from an annotated payload.
    public init(
        owner: CmuxTopMemoryOwner,
        defaultReason: String,
        processIDs: [Int],
        processReasons: [Int: String] = [:]
    ) {
        self.owner = owner
        self.defaultReason = defaultReason
        self.processIDs = processIDs
        self.processReasons = processReasons
    }
}

/// Resolves overlapping workspace/pane/surface nodes into one PID map.
public struct CmuxTopMemoryAttributionResolver: Sendable {
    /// Creates a stateless attribution reducer.
    public init() {}

    /// Applies specificity and common-owner rules in input traversal order.
    public func resolve(
        nodes: [CmuxTopMemoryAttributionNode]
    ) -> [Int: CmuxTopMemoryAttribution] {
        var result: [Int: CmuxTopMemoryAttribution] = [:]
        var ambiguousSpecificityByPID: [Int: Int] = [:]
        var commonOwnerSourceSpecificityByPID: [Int: Int] = [:]

        for node in nodes {
            let attribution = CmuxTopMemoryAttribution(
                owner: node.owner,
                reason: node.defaultReason
            )
            let newSpecificity = node.owner.specificity
            var seenPIDs: Set<Int> = []
            for pid in node.processIDs where seenPIDs.insert(pid).inserted {
                let processReason = node.processReasons[pid] ?? node.defaultReason
                let processAttribution = processReason == attribution.reason
                    ? attribution
                    : CmuxTopMemoryAttribution(owner: node.owner, reason: processReason)
                if let ambiguousSpecificity = ambiguousSpecificityByPID[pid] {
                    guard newSpecificity > ambiguousSpecificity else { continue }
                    ambiguousSpecificityByPID.removeValue(forKey: pid)
                    commonOwnerSourceSpecificityByPID.removeValue(forKey: pid)
                }
                guard let existing = result[pid] else {
                    result[pid] = processAttribution
                    continue
                }
                if existing == processAttribution { continue }
                let existingSpecificity = existing.owner.specificity
                let commonOwnerSourceSpecificity = commonOwnerSourceSpecificityByPID[pid]
                let existingSourceSpecificity = commonOwnerSourceSpecificity ?? existingSpecificity
                let mergedSourceSpecificity = max(existingSourceSpecificity, newSpecificity)
                if let commonOwner = existing.owner.commonOwner(with: processAttribution.owner),
                   commonOwnerSourceSpecificity != nil || newSpecificity == existingSourceSpecificity {
                    let sharedReason: String
                    switch commonOwner.specificity {
                    case 3: sharedReason = "shared-surface-process-tree"
                    case 2: sharedReason = "shared-pane-process-tree"
                    default: sharedReason = "shared-workspace-process-tree"
                    }
                    result[pid] = CmuxTopMemoryAttribution(
                        owner: commonOwner,
                        reason: sharedReason
                    )
                    commonOwnerSourceSpecificityByPID[pid] = mergedSourceSpecificity
                } else if newSpecificity > existingSourceSpecificity {
                    result[pid] = processAttribution
                    commonOwnerSourceSpecificityByPID.removeValue(forKey: pid)
                } else if newSpecificity == existingSourceSpecificity {
                    result.removeValue(forKey: pid)
                    ambiguousSpecificityByPID[pid] = newSpecificity
                    commonOwnerSourceSpecificityByPID.removeValue(forKey: pid)
                }
            }
        }
        return result
    }
}
