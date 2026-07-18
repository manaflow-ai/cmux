#if DEBUG
import SwiftUI

/// Presents the complete fixture conversation as a compact timestamped log.
struct SignalChatScreen: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = SignalTheme(scheme: colorScheme)

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Chat")
                    .font(.system(.title, design: .default, weight: .heavy))
                    .foregroundStyle(theme.ink)
                    .padding(.bottom, 16)

                ForEach(DesignGalleryFixtures.chatEntries) { entry in
                    SignalChatEntryRow(entry: entry, theme: theme)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .defaultScrollAnchor(.bottom)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SignalTriageBar(theme: theme)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg0.ignoresSafeArea())
    }
}
#endif
