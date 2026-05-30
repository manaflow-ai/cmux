import SwiftUI

/// One row inside a ``SettingsCard``: a left-aligned title (and
/// optional subtitle), the row's control on the right, and an
/// optional ``configurationReview`` annotation that exposes the
/// underlying cmux.json path next to the row when the host enables
/// "show config paths".
///
/// Mirrors the legacy in-app `SettingsCardRow`: 13pt medium title,
/// 11pt secondary subtitle, 14pt horizontal padding, 9pt vertical
/// padding. The trailing slot accepts any SwiftUI view; common
/// patterns are a `Toggle`, a `Picker`, a `Stepper`, or a custom
/// `HStack` of the control plus secondary affordances.
@MainActor
public struct SettingsCardRow<Trailing: View>: View {
    let configurationReview: SettingsConfigurationReview
    let title: String
    let subtitle: String?
    let controlWidth: CGFloat?
    let searchAnchorID: String?
    @ViewBuilder let trailing: Trailing

    // The settings root injects the built search index so each row can
    // map the cmux.json path(s) it declares via `configurationReview`
    // into the sidebar/search anchor id(s) the navigation layer scrolls
    // to and highlights. `nil` outside the settings window (previews,
    // host embedding without the index), in which case the row simply
    // doesn't participate in search navigation.
    @Environment(\.settingsSearchIndex) private var searchIndex

    /// Anchor ids that make the row `scrollTo`-addressable and eligible
    /// for the search-result highlight pulse. An explicit
    /// ``searchAnchorID`` wins (used by `.action` / `.settingsOnly` /
    /// custom-control rows that don't write a single cmux.json key);
    /// otherwise the row resolves the path(s) it declares via
    /// `configurationReview` through the injected index. Empty when no
    /// index is injected and no explicit anchor is set.
    private var searchAnchorIDs: [String] {
        if let searchAnchorID { return [searchAnchorID] }
        guard let searchIndex else { return [] }
        return configurationReview.paths.compactMap(searchIndex.anchorID(forSettingsPath:))
    }

    public init(
        configurationReview: SettingsConfigurationReview = .action,
        searchAnchorID: String? = nil,
        _ title: String,
        subtitle: String? = nil,
        controlWidth: CGFloat? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.configurationReview = configurationReview
        self.searchAnchorID = searchAnchorID
        self.title = title
        self.subtitle = subtitle
        self.controlWidth = controlWidth
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if let controlWidth {
                    trailing.frame(width: controlWidth, alignment: .trailing)
                } else {
                    trailing
                }
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsSearchAnchors(searchAnchorIDs)
    }
}
