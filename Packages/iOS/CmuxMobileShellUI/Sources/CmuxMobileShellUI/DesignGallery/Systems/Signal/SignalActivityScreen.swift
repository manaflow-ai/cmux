#if DEBUG
import SwiftUI

/// Displays every fixture event in Signal's absolute-time activity table.
struct SignalActivityScreen: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = SignalTheme(scheme: colorScheme)

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(Array(DesignGalleryFixtures.activityDays.enumerated()), id: \.offset) { _, day in
                    VStack(spacing: 0) {
                        HStack {
                            SignalSectionLabel(text: day.dayLabel, color: theme.ink)
                            Spacer()
                            Text("\(day.entries.count)")
                                .font(.system(.footnote, design: .monospaced, weight: .regular))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .frame(minHeight: 24)

                        ForEach(day.entries) { entry in
                            SignalActivityRow(entry: entry, theme: theme)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 112)
            .padding(.bottom, 16)
        }
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                Text("Activity")
                    .font(.system(.title, design: .default, weight: .heavy))
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 38)
                    .background(theme.bg0)

                SignalSummaryStrip(theme: theme)
            }
            .padding(.top, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SignalTriageBar(theme: theme)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg0.ignoresSafeArea())
    }
}
#endif
