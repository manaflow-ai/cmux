#if DEBUG
import SwiftUI

/// DEBUG ONLY: a workspace row in the no-Home prototype's sidebar: a folder glyph, the name and the branch.
struct ChiefNoHomeWorkspaceRow: View {
    let workspace: ChiefNoHomeWorkspace
    var selected = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.stack").font(.noHomeBody).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.name).font(.noHomeBody).lineLimit(1)
                Text(workspace.branch).font(.noHomeCodeCaption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.22) : .clear))
    }
}
#endif
