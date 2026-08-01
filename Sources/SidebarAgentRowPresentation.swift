import Foundation

/// Pure display text for one immutable agent-row snapshot.
///
/// User-authored surface names stay distinct from live titles so unnamed rows
/// retain their existing text and automatic titles never masquerade as names.
struct SidebarAgentRowPresentation: Equatable {
    static let maximumSurfaceNameLength = 48

    let primaryText: String
    let fullPrimaryText: String

    init(row: SidebarAgentStatusRow) {
        self.init(
            paneLabel: row.paneLabel,
            agentDisplayName: Self.agentDisplayName(statusKey: row.statusKey),
            surfaceName: row.surfaceName
        )
    }

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
        let characters = Array(value)
        guard characters.count > maximumSurfaceNameLength else { return value }
        let leadingCount = maximumSurfaceNameLength / 2
        let trailingCount = maximumSurfaceNameLength - leadingCount - 1
        return String(characters.prefix(leadingCount))
            + "…"
            + String(characters.suffix(trailingCount))
    }
}

extension SidebarAgentStatusRow {
    var presentation: SidebarAgentRowPresentation {
        SidebarAgentRowPresentation(row: self)
    }
}
