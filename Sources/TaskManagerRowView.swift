import CmuxAppKitSupportUI
import CmuxFoundation
import SwiftUI

/// Row view rendered inside the lazy list subtree. Conforms to
/// `Equatable` so SwiftUI can skip body re-evaluation when the `row`
/// snapshot is unchanged, even if the parent rebuilt the closure
/// bundle on a refresh tick. Closures are intentionally excluded from
/// `==`; they're expected to be stable in semantics (capture the same
/// model above the snapshot boundary) but their identity changes every
/// render. Comparing closure identity would defeat the optimization
/// and re-introduce the 0.64.8 memory leak (issue #4529).
struct CmuxTaskManagerRowView: View, Equatable {
    let row: CmuxTaskManagerRow
    let onViewWorkspace: @MainActor () -> Void
    let onViewTerminal: @MainActor () -> Void
    let onKillProcess: @MainActor () -> Void
    let onActivate: @MainActor () -> Void
    var onCloseTerminal: @MainActor () -> Void = {}

    static func == (lhs: CmuxTaskManagerRowView, rhs: CmuxTaskManagerRowView) -> Bool {
        // Closures excluded on purpose: the parent rebuilds the action
        // bundle on every render tick, but the row payload is what
        // actually drives visible state. Comparing closure identity
        // would defeat `.equatable()` at the ForEach call site and
        // re-introduce the 0.64.8 memory leak.
        lhs.row == rhs.row
    }

    var body: some View {
        Group {
            if row.canViewWorkspace || row.canViewTerminal {
                Button(action: onActivate) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .contextMenu {
            if row.canViewWorkspace {
                Button {
                    onViewWorkspace()
                } label: {
                    Label(
                        String(localized: "taskManager.contextMenu.viewWorkspace", defaultValue: "View Workspace"),
                        systemImage: "rectangle.stack"
                    )
                }
            }
            if row.canViewTerminal {
                Button {
                    onViewTerminal()
                } label: {
                    Label(
                        String(localized: "taskManager.contextMenu.viewTerminal", defaultValue: "View Terminal"),
                        systemImage: "terminal"
                    )
                }
            }
            if row.canCloseTerminal {
                Divider()
                Button {
                    onCloseTerminal()
                } label: {
                    Label(
                        String(localized: "taskManager.contextMenu.closeTerminal", defaultValue: "Close Terminal"),
                        systemImage: "xmark.square"
                    )
                }
            }
            if row.canKillProcess {
                if (row.canViewWorkspace || row.canViewTerminal) && !row.canCloseTerminal {
                    Divider()
                }
                Button {
                    onKillProcess()
                } label: {
                    Label(
                        String(localized: "taskManager.contextMenu.killProcess", defaultValue: "Kill Process..."),
                        systemImage: "xmark.octagon"
                    )
                }
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Color.clear
                    .frame(width: CGFloat(row.level) * 14)
                rowIcon
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.title)
                        .cmuxFont(size: 12.5)
                        .lineLimit(1)
                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .cmuxFont(size: 11)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let agentStatus = row.agentStatus {
                HStack(spacing: 4) {
                    Text(agentStatus.state.label)
                        .foregroundStyle(agentStatus.state.tint)
                    if let elapsedText = agentStatus.elapsedText {
                        Text(elapsedText)
                            .foregroundStyle(.secondary)
                    }
                }
                .cmuxFont(size: 11, weight: .medium)
                .lineLimit(1)
                .frame(width: 124, alignment: .trailing)
                .accessibilityElement(children: .combine)
            }

            Text(CmuxTaskManagerFormat.cpu(row.resources.cpuPercent))
                .frame(width: 82, alignment: .trailing)
            Text(CmuxTaskManagerFormat.bytes(row.resources.memoryBytes))
                .frame(width: 96, alignment: .trailing)
            Text("\(row.resources.processCount)")
                .frame(width: 70, alignment: .trailing)
        }
        .cmuxFont(size: 12.5, design: .default)
        .monospacedDigit()
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .opacity(row.isDimmed ? 0.68 : 1)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var rowIcon: some View {
        if let agentAssetName = row.agentAssetName {
            CmuxResolvedIconImage(request: CmuxResolvedIconRequest(
                source: .asset(name: agentAssetName, bundle: .main),
                size: NSSize(width: 14, height: 14)
            ))
            .frame(width: 14, height: 14)
        } else {
            CmuxSystemSymbolImage(magnified: row.kind.systemImage, pointSize: 12, tint: row.kind.tint)
                .frame(width: 14)
        }
    }
}
