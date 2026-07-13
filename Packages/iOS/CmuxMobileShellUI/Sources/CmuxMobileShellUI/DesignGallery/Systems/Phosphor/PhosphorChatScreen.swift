#if DEBUG
import SwiftUI

/// Renders the complete shared conversation as a dense, bubble-light transcript.
struct PhosphorChatScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var entriesVisible = false

    var body: some View {
        let theme = PhosphorTheme(scheme: colorScheme)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(DesignGalleryFixtures.chatEntries) { entry in
                    PhosphorChatEntryView(entry: entry)
                        .opacity(entriesVisible ? 1.0 : 0.0)
                        .offset(y: reduceMotion || entriesVisible ? 0 : 4)
                }
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
        .background(theme.bg0.ignoresSafeArea())
        .onAppear {
            withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.18)) {
                entriesVisible = true
            }
        }
    }
}
#endif
