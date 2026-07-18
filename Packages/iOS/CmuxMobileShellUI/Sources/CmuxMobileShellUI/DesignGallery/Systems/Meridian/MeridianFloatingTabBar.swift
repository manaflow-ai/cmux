#if DEBUG
import CmuxMobileSupport
import SwiftUI

/// Renders Meridian's bottom-centered glass navigation capsule.
struct MeridianFloatingTabBar: View {
    let selectedPage: DesignGalleryPage

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            tabButton(title: "Home", symbol: "house.fill", page: .hub)
            tabButton(title: "Activity", symbol: "bell.fill", page: .activity)
            tabButton(title: "Settings", symbol: "gearshape.fill", page: .settings)
        }
        .padding(6)
        .mobileGlassPill()
        .tint(theme.accent)
    }

    private var theme: MeridianTheme {
        MeridianTheme(scheme: colorScheme)
    }

    private var selectedRootPage: DesignGalleryPage {
        switch selectedPage {
        case .activity: .activity
        case .settings: .settings
        default: .hub
        }
    }

    @ViewBuilder
    private func tabButton(title: String, symbol: String, page: DesignGalleryPage) -> some View {
        let isSelected = selectedRootPage == page
        Button {} label: {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.body)
                    .frame(height: 20)
                    .overlay(alignment: .topTrailing) {
                        if page == .hub, needsYouCount > 0 {
                            Text("\(needsYouCount)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(theme.accentForeground)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(theme.needsYou, in: Circle())
                                .offset(x: 10, y: -7)
                        }
                    }
                Text(title)
                    .font(.caption)
            }
            .foregroundStyle(isSelected ? theme.accent : theme.secondaryLabel)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(MeridianPressButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var needsYouCount: Int {
        DesignGalleryFixtures.workspaces.reduce(into: 0) { count, workspace in
            if case .needsYou = workspace.state { count += 1 }
        }
    }
}
#endif
