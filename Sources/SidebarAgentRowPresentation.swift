import CmuxSidebar
import Foundation

/// Pure display text for one immutable agent-row snapshot.
///
/// User-authored surface names stay distinct from live titles so unnamed rows
/// retain their existing text and automatic titles never masquerade as names.
struct SidebarAgentRowPresentation: Equatable {
    static let maximumSurfaceNameLength = 48

    let primaryText: String
    let fullPrimaryText: String

    init(paneLabel: String?, agentDisplayName: String, surfaceName: String?) {
        let base = Self.normalized(paneLabel) ?? agentDisplayName
        guard let fullSurfaceName = Self.normalized(surfaceName), fullSurfaceName != base else {
            primaryText = base
            fullPrimaryText = base
            return
        }

        primaryText = [base, Self.boundedSurfaceName(fullSurfaceName)].joined(separator: " · ")
        fullPrimaryText = [base, fullSurfaceName].joined(separator: " · ")
    }

    static func agentDisplayName(statusKey: String) -> String {
        statusKey
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func boundedSurfaceName(_ value: String) -> String {
        guard let firstOmittedIndex = value.index(
            value.startIndex,
            offsetBy: maximumSurfaceNameLength,
            limitedBy: value.endIndex
        ), firstOmittedIndex != value.endIndex else { return value }
        let leadingCount = maximumSurfaceNameLength / 2
        let trailingCount = maximumSurfaceNameLength - leadingCount - 1
        let leadingEnd = value.index(value.startIndex, offsetBy: leadingCount)
        let trailingStart = value.index(value.endIndex, offsetBy: -trailingCount)
        return String(value[..<leadingEnd])
            + "…"
            + String(value[trailingStart...])
    }
}

extension SidebarAgentStatusRow {
    init(
        panelId: UUID,
        statusKey: String,
        value: String?,
        icon: String?,
        color: String?,
        url: URL?,
        format: SidebarMetadataFormat,
        lifecycle: AgentHibernationLifecycleState?,
        paneLabel: String?,
        surfaceName: String?,
        priority: Int,
        timestamp: Date
    ) {
        self.panelId = panelId
        self.statusKey = statusKey
        self.value = value
        self.icon = icon
        self.color = color
        self.url = url
        self.format = format
        self.lifecycle = lifecycle
        self.paneLabel = paneLabel
        self.surfaceName = surfaceName
        presentation = SidebarAgentRowPresentation(
            paneLabel: paneLabel,
            agentDisplayName: SidebarAgentRowPresentation.agentDisplayName(statusKey: statusKey),
            surfaceName: surfaceName
        )
        self.priority = priority
        self.timestamp = timestamp
    }
}
