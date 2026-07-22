internal import CMUXMobileCore
internal import CmuxMobileShellModel
internal import Foundation

extension MobileShellComposite {
    static func normalizedPairingURL(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CmxPairingURLScheme.hasPairingScheme(trimmed) else {
            return trimmed
        }
        let scalars = trimmed.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    static func diagnosticSurfaceHandle(_ surfaceID: String) -> UInt32 {
        // Swift's Hasher is randomly seeded for each process. The same surface
        // remains correlatable inside one report, but the exported number cannot
        // become a stable cross-launch identifier.
        var hasher = Hasher()
        hasher.combine(surfaceID)
        return UInt32(truncatingIfNeeded: hasher.finalize())
    }

    static func workspaceActionCapabilities(
        from supportedHostCapabilities: Set<String>,
        allowsMacScopedMutations: Bool
    ) -> MobileWorkspaceActionCapabilities {
        MobileWorkspaceActionCapabilities(
            supportsWorkspaceActions: supportedHostCapabilities.contains("workspace.actions.v1"),
            supportsReadStateActions: supportedHostCapabilities.contains("workspace.read_state.v1"),
            supportsCloseActions: supportedHostCapabilities.contains("workspace.close.v1"),
            supportsMoveActions: supportedHostCapabilities.contains("workspace.move.v1") && allowsMacScopedMutations,
            supportsGroupActions: supportedHostCapabilities.contains("workspace.group_actions.v1") && allowsMacScopedMutations,
            supportsGroupCreate: supportedHostCapabilities.contains("workspace.group_create.v1") && allowsMacScopedMutations
        )
    }

    static func routeSortsBefore(_ left: CmxAttachRoute, _ right: CmxAttachRoute) -> Bool {
        if left.priority == right.priority {
            return left.id < right.id
        }
        return left.priority < right.priority
    }
}
