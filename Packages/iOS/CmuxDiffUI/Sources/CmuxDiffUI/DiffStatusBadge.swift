import CmuxMobileRPC
import SwiftUI

struct DiffStatusBadge: View {
    let status: MobileDiffFileStatus

    var body: some View {
        Text(shortLabel)
            .font(.caption2.bold().monospaced())
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel(accessibilityLabel)
    }

    private var shortLabel: String {
        let localized = DiffLocalized()
        return switch status {
        case .added: localized.string("diff.status.added.short", defaultValue: "A")
        case .modified: localized.string("diff.status.modified.short", defaultValue: "M")
        case .deleted: localized.string("diff.status.deleted.short", defaultValue: "D")
        case .renamed: localized.string("diff.status.renamed.short", defaultValue: "R")
        case .copied: localized.string("diff.status.copied.short", defaultValue: "C")
        case .untracked: localized.string("diff.status.untracked.short", defaultValue: "U")
        }
    }

    private var accessibilityLabel: String {
        let localized = DiffLocalized()
        return switch status {
        case .added: localized.string("diff.status.added", defaultValue: "Added")
        case .modified: localized.string("diff.status.modified", defaultValue: "Modified")
        case .deleted: localized.string("diff.status.deleted", defaultValue: "Deleted")
        case .renamed: localized.string("diff.status.renamed", defaultValue: "Renamed")
        case .copied: localized.string("diff.status.copied", defaultValue: "Copied")
        case .untracked: localized.string("diff.status.untracked", defaultValue: "Untracked")
        }
    }

    private var color: Color {
        switch status {
        case .added, .untracked: .green
        case .modified: .orange
        case .deleted: .red
        case .renamed: .blue
        case .copied: .purple
        }
    }
}
