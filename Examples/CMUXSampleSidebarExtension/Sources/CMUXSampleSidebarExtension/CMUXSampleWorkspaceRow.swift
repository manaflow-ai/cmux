import CmuxExtensionKit
import SwiftUI

public struct CMUXSampleWorkspaceRow: View {
    private let workspace: CMUXSidebarWorkspace
    private let isSelected: Bool
    private let onSelect: () -> Void

    public init(
        workspace: CMUXSidebarWorkspace,
        isSelected: Bool,
        onSelect: @escaping () -> Void
    ) {
        self.workspace = workspace
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    public var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(workspace.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if workspace.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    if workspace.unreadCount > 0 {
                        Text("\(workspace.unreadCount)")
                            .font(.system(size: 10, weight: .bold))
                            .monospacedDigit()
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.16), in: Capsule())
                    }
                }

                if let detail = workspace.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !workspace.listeningPorts.isEmpty {
                    Text("Ports \(workspace.listeningPorts.map(String.init).joined(separator: ", "))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
    }
}
