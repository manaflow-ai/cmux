import CmuxFoundation
import SwiftUI

/// Equatable worktree row rendered from an immutable Git snapshot.
struct WorktreeSidebarRowView: View, Equatable {
    let row: WorktreeSidebarRow
    let actions: WorktreeSidebarRowActions
    @State private var isHovering = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.triangle.branch")
                .cmuxFont(size: 11, weight: .regular)
                .foregroundStyle(.secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.worktree.name)
                    .cmuxFont(size: 12.5, weight: .regular)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(detailText)
                    .cmuxFont(size: 10, weight: .regular)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            statusIndicators

            if row.worktree.isMain {
                Image(systemName: "house")
                    .cmuxFont(size: 10, weight: .regular)
                    .foregroundStyle(.secondary)
                    .safeHelp(String(
                        localized: "worktreeSidebar.main.help",
                        defaultValue: "Main worktree"
                    ))
            } else {
                Button(role: .destructive) {
                    actions.delete(row)
                } label: {
                    Image(systemName: row.worktree.isPrunable ? "trash.slash" : "trash")
                        .cmuxFont(size: 10, weight: .regular)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(row.worktree.isLocked)
                .opacity(isHovering ? 1 : 0.68)
                .safeHelp(deleteHelp)
                .accessibilityLabel(String(
                    localized: "worktreeSidebar.delete.action",
                    defaultValue: "Remove Worktree"
                ))
            }
        }
        .padding(.leading, 28)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) {
            guard !row.worktree.isPrunable else { return }
            actions.openTerminal(row)
        }
        .contextMenu {
            Button(String(
                localized: "worktreeSidebar.openTerminal",
                defaultValue: "Open Terminal Inside"
            )) {
                actions.openTerminal(row)
            }
            .disabled(row.worktree.isPrunable)

            if !row.worktree.isMain {
                Divider()
                Button(role: .destructive) {
                    actions.delete(row)
                } label: {
                    Text(String(
                        localized: "worktreeSidebar.delete.action",
                        defaultValue: "Remove Worktree"
                    ))
                }
                .disabled(row.worktree.isLocked)
            }
        }
        .accessibilityAction(named: Text(String(
            localized: "worktreeSidebar.openTerminal",
            defaultValue: "Open Terminal Inside"
        ))) {
            if !row.worktree.isPrunable {
                actions.openTerminal(row)
            }
        }
    }

    @ViewBuilder
    private var statusIndicators: some View {
        HStack(spacing: 4) {
            if !row.worktree.isPrunable {
                switch row.status {
                case .loading:
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                case .dirty:
                    Circle()
                        .fill(.orange)
                        .frame(width: 7, height: 7)
                        .safeHelp(String(
                            localized: "worktreeSidebar.dirty.help",
                            defaultValue: "Uncommitted changes"
                        ))
                case .unavailable:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .cmuxFont(size: 9, weight: .semibold)
                        .foregroundStyle(.orange)
                        .safeHelp(String(
                            localized: "worktreeSidebar.statusUnavailable.help",
                            defaultValue: "Couldn’t read this worktree’s status."
                        ))
                case .unknown, .clean:
                    EmptyView()
                }
            }

            if row.worktree.isLocked {
                Image(systemName: "lock.fill")
                    .cmuxFont(size: 9, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .safeHelp(lockedHelp)
            } else if row.worktree.isPrunable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .cmuxFont(size: 9, weight: .semibold)
                    .foregroundStyle(.orange)
                    .safeHelp(prunableHelp)
            }
        }
    }

    private var detailText: String {
        let branch: String
        if let branchName = row.worktree.branchName {
            branch = branchName
        } else if row.worktree.isDetached {
            let shortHead = row.worktree.head.map { String($0.prefix(8)) } ?? ""
            let format = String(
                localized: "worktreeSidebar.branch.detached",
                defaultValue: "Detached at %@"
            )
            branch = String.localizedStringWithFormat(format, shortHead)
        } else {
            branch = String(
                localized: "worktreeSidebar.branch.none",
                defaultValue: "No branch"
            )
        }

        if row.worktree.isLocked {
            let format = String(
                localized: "worktreeSidebar.locked.subtitle",
                defaultValue: "%1$@ · Locked: %2$@"
            )
            let reason = row.worktree.lockReason ?? String(
                localized: "worktreeSidebar.locked.noReason",
                defaultValue: "No reason provided"
            )
            return String.localizedStringWithFormat(format, branch, reason)
        }
        if row.worktree.isPrunable {
            let format = String(
                localized: "worktreeSidebar.prunable.subtitle",
                defaultValue: "%1$@ · Prunable: %2$@"
            )
            let reason = row.worktree.prunableReason ?? String(
                localized: "worktreeSidebar.prunable.noReason",
                defaultValue: "Working directory is missing"
            )
            return String.localizedStringWithFormat(format, branch, reason)
        }
        return branch
    }

    private var lockedHelp: String {
        if let reason = row.worktree.lockReason, !reason.isEmpty {
            let format = String(
                localized: "worktreeSidebar.locked.help.reason",
                defaultValue: "Locked: %@"
            )
            return String.localizedStringWithFormat(format, reason)
        }
        return String(
            localized: "worktreeSidebar.locked.help",
            defaultValue: "Locked worktree"
        )
    }

    private var prunableHelp: String {
        row.worktree.prunableReason ?? String(
            localized: "worktreeSidebar.prunable.noReason",
            defaultValue: "Working directory is missing"
        )
    }

    private var deleteHelp: String {
        if row.worktree.isLocked { return lockedHelp }
        if row.worktree.isPrunable {
            return String(
                localized: "worktreeSidebar.prunable.action",
                defaultValue: "Prune stale worktree"
            )
        }
        return String(
            localized: "worktreeSidebar.delete.action",
            defaultValue: "Remove Worktree"
        )
    }
}
