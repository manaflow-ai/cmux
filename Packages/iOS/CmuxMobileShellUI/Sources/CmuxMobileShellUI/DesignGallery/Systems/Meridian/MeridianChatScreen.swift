#if DEBUG
import SwiftUI

/// Displays the full shared conversation with native chat metrics and a glass composer.
struct MeridianChatScreen: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                Text("Chat")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(theme.label)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(DesignGalleryFixtures.chatEntries) { entry in
                    MeridianChatEntryView(entry: entry)
                }
            }
            .padding(.horizontal, theme.horizontalInset)
            .padding(.top, 14)
            .padding(.bottom, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .defaultScrollAnchor(.bottom)
        .background(theme.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 8) {
            MeridianComposer()
                .padding(.horizontal, 12)
        }
        .tint(theme.accent)
    }

    private var theme: MeridianTheme {
        MeridianTheme(scheme: colorScheme)
    }
}
#endif
