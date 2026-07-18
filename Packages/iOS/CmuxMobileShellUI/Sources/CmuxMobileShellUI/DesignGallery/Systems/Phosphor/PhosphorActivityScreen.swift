#if DEBUG
import SwiftUI

/// Renders every fixture event in Phosphor's single dense chronological feed.
struct PhosphorActivityScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var feedVisible = false
    private let typography = PhosphorTypography()

    var body: some View {
        let theme = PhosphorTheme(scheme: colorScheme)

        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(DesignGalleryFixtures.activityDays, id: \.dayLabel) { day in
                    Section {
                        ForEach(day.entries) { entry in
                            PhosphorActivityRow(entry: entry)
                                .opacity(feedVisible ? 1.0 : 0.0)
                                .offset(y: reduceMotion || feedVisible ? 0 : 4)
                        }
                    } header: {
                        Text(day.dayLabel.uppercased())
                            .font(typography.caption)
                            .tracking(0.8)
                            .foregroundStyle(theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(theme.bg0)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .background(theme.bg0.ignoresSafeArea())
        .onAppear {
            withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.18)) {
                feedVisible = true
            }
        }
    }
}
#endif
