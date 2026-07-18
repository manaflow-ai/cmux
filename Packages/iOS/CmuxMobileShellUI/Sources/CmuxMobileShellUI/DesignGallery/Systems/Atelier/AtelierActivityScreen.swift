#if DEBUG
import SwiftUI

/// Presents every shared activity entry as a spacious chronological journal.
struct AtelierActivityScreen: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = AtelierTheme(scheme: colorScheme)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                Text("Activity")
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                    .foregroundStyle(theme.textPrimary)

                ForEach(Array(DesignGalleryFixtures.activityDays.enumerated()), id: \.offset) { _, day in
                    VStack(alignment: .leading, spacing: 16) {
                        Text(day.dayLabel)
                            .font(.system(size: 20, weight: .semibold, design: .serif))
                            .foregroundStyle(theme.textPrimary)

                        ForEach(day.entries) { entry in
                            AtelierActivityEntryView(entry: entry)

                            if entry.id != day.entries.last?.id {
                                Divider()
                                    .overlay(theme.hairline)
                                    .padding(.leading, 34)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(theme.background.ignoresSafeArea())
    }
}
#endif
