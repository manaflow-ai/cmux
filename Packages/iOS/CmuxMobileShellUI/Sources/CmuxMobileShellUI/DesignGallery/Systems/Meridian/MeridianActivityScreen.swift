#if DEBUG
import SwiftUI

/// Renders every shared activity day and event as a native notification-center list.
struct MeridianActivityScreen: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Activity")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(theme.label)
                .padding(.horizontal, theme.horizontalInset)
                .padding(.top, 14)
                .padding(.bottom, 6)

            List {
                ForEach(Array(DesignGalleryFixtures.activityDays.enumerated()), id: \.offset) { _, day in
                    Section(day.dayLabel) {
                        ForEach(day.entries) { entry in
                            MeridianActivityRow(entry: entry)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.ignoresSafeArea())
        .tint(theme.accent)
    }

    private var theme: MeridianTheme {
        MeridianTheme(scheme: colorScheme)
    }
}
#endif
