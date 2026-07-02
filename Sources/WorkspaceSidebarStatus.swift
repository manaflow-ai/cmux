import Foundation

struct WorkspaceSidebarStatus: Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let systemImage: String
    let colorHex: String
}

enum WorkspaceSidebarStatusCatalog {
    static let statuses: [WorkspaceSidebarStatus] = [
        WorkspaceSidebarStatus(
            id: "open",
            label: String(localized: "workspaceStatus.open.label", defaultValue: "Open"),
            systemImage: "circle",
            colorHex: "#8E8E93"
        ),
        WorkspaceSidebarStatus(
            id: "active",
            label: String(localized: "workspaceStatus.active.label", defaultValue: "Active"),
            systemImage: "play.circle.fill",
            colorHex: "#0A84FF"
        ),
        WorkspaceSidebarStatus(
            id: "done",
            label: String(localized: "workspaceStatus.done.label", defaultValue: "Done"),
            systemImage: "checkmark.circle.fill",
            colorHex: "#30D158"
        ),
        WorkspaceSidebarStatus(
            id: "blocked",
            label: String(localized: "workspaceStatus.blocked.label", defaultValue: "Blocked"),
            systemImage: "exclamationmark.octagon.fill",
            colorHex: "#FF9F0A"
        ),
    ]

    static func status(for id: String?) -> WorkspaceSidebarStatus? {
        guard let normalized = normalizedStatusId(id) else { return nil }
        return statuses.first { $0.id == normalized }
    }

    static func normalizedStatusId(_ raw: String?) -> String? {
        let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !normalized.isEmpty else { return nil }
        guard statuses.contains(where: { $0.id == normalized }) else { return nil }
        return normalized
    }

    static func nextStatusId(after currentId: String?) -> String? {
        guard !statuses.isEmpty else { return nil }
        guard let current = normalizedStatusId(currentId),
              let index = statuses.firstIndex(where: { $0.id == current }) else {
            return statuses[0].id
        }
        let nextIndex = statuses.index(after: index)
        guard nextIndex < statuses.endIndex else { return nil }
        return statuses[nextIndex].id
    }
}
