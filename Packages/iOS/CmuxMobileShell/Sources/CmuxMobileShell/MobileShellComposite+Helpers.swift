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
        var hash: UInt32 = 2_166_136_261
        for byte in surfaceID.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return hash
    }

    static func workspaceActionCapabilities(
        from supportedHostCapabilities: Set<String>
    ) -> MobileWorkspaceActionCapabilities {
        MobileWorkspaceActionCapabilities(
            supportsWorkspaceActions: supportedHostCapabilities.contains("workspace.actions.v1"),
            supportsReadStateActions: supportedHostCapabilities.contains("workspace.read_state.v1"),
            supportsCloseActions: supportedHostCapabilities.contains("workspace.close.v1")
        )
    }

    static func routeSortsBefore(_ left: CmxAttachRoute, _ right: CmxAttachRoute) -> Bool {
        if left.priority == right.priority {
            return left.id < right.id
        }
        return left.priority < right.priority
    }
}
