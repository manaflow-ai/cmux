internal import CmuxMobileRPC
internal import SwiftUI

/// GitHub-filter-style comparison-base menu with the active choice checked.
struct DiffBasePicker: View {
    let selectedKind: MobileChangesBaseKind
    let select: @MainActor @Sendable (MobileChangesBaseKind) -> Void

    var body: some View {
        Menu {
            baseButton(.workingTree, title: String(
                localized: "diff.base.workingTree",
                defaultValue: "Working tree",
                bundle: .module
            ))
            baseButton(.lastTurn, title: String(
                localized: "diff.base.lastTurn",
                defaultValue: "Last agent turn",
                bundle: .module
            ))
            baseButton(.branchBase, title: String(
                localized: "diff.base.branchBase",
                defaultValue: "Branch base",
                bundle: .module
            ))
        } label: {
            HStack(spacing: 4) {
                Text(selectedTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.secondary.opacity(0.10), in: Capsule())
        }
        .accessibilityLabel(String(
            localized: "diff.base.accessibility",
            defaultValue: "Comparison base",
            bundle: .module
        ))
    }

    private func baseButton(_ kind: MobileChangesBaseKind, title: String) -> some View {
        Button { select(kind) } label: {
            Label(title, systemImage: selectedKind == kind ? "checkmark" : "circle")
        }
    }

    private var selectedTitle: String {
        switch selectedKind {
        case .workingTree:
            String(localized: "diff.base.workingTree", defaultValue: "Working tree", bundle: .module)
        case .lastTurn:
            String(localized: "diff.base.lastTurn", defaultValue: "Last agent turn", bundle: .module)
        case .branchBase:
            String(localized: "diff.base.branchBase", defaultValue: "Branch base", bundle: .module)
        }
    }
}
