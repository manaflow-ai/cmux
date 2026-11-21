#if DEBUG
import SwiftUI

/// DEBUG ONLY: the sidebar column of the no-Home prototype: its rows on the sidebar's material, with no Home row
/// and no separate Home page behind it.
struct ChiefNoHomeSidebar<Rows: View>: View {
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            rows
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil").font(.noHomeCaptionEmphasis)
                Text("New thread").font(.noHomeBody)
            }
            .foregroundStyle(.secondary).padding(10)
        }
        .padding(.horizontal, 6).padding(.top, 8)
        .frame(width: 270)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }
}
#endif
