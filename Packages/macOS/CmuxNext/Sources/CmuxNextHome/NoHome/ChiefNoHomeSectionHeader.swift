#if DEBUG
import SwiftUI

/// DEBUG ONLY: a sidebar section title in the no-Home prototype (Threads, Workspaces).
struct ChiefNoHomeSectionHeader: View {
    let title: String

    var body: some View {
        Text(title).font(.noHomeCaptionEmphasis).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
