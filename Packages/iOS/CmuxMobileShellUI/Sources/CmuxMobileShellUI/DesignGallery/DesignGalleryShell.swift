#if DEBUG
import CmuxMobileSupport
import SwiftUI

/// Browses the six shared pages rendered by one candidate design system.
struct DesignGalleryShell: View {
    let system: DesignGallerySystem

    @State private var page: DesignGalleryPage = .hub
    @State private var colorSchemeOverride: ColorScheme

    /// Creates the browser for one candidate.
    /// - Parameters:
    ///   - system: The candidate design system to browse.
    ///   - initialPage: The page shown first; defaults to the hub.
    ///   - initialScheme: A forced starting color scheme, or `nil` for the
    ///     candidate's default (dark for Phosphor, light otherwise).
    init(
        system: DesignGallerySystem,
        initialPage: DesignGalleryPage = .hub,
        initialScheme: ColorScheme? = nil
    ) {
        self.system = system
        _page = State(initialValue: initialPage)
        _colorSchemeOverride = State(
            initialValue: initialScheme ?? (system == .phosphor ? .dark : .light)
        )
    }

    var body: some View {
        ZStack {
            system.content(page: page)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.colorScheme, colorSchemeOverride)
        }
        .navigationTitle("\(system.number) \(system.displayName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    colorSchemeOverride = colorSchemeOverride == .dark ? .light : .dark
                } label: {
                    Image(systemName: colorSchemeOverride == .dark ? "sun.max" : "moon")
                }
                .accessibilityLabel(L10n.string(
                    "mobile.designGallery.schemeToggle.accessibilityLabel",
                    defaultValue: "Toggle Light or Dark Appearance"
                ))
                .accessibilityIdentifier("DesignGallerySchemeToggle")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            pagePicker
                .background(.bar)
        }
    }

    private var pagePicker: some View {
        HStack(spacing: 4) {
            ForEach(DesignGalleryPage.allCases) { candidatePage in
                Button {
                    page = candidatePage
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: candidatePage.symbolName)
                            .font(.body)
                        Text(candidatePage.title)
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 2)
                    .foregroundStyle(page == candidatePage ? Color.accentColor : Color.secondary)
                    .background {
                        Capsule()
                            .fill(page == candidatePage ? Color.accentColor.opacity(0.14) : Color.clear)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("DesignGalleryPage-\(candidatePage.rawValue)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}
#endif
