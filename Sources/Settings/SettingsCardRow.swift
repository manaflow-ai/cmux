import AppKit
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers

struct SettingsCardRow<Trailing: View>: View {
    let configurationReview: SettingsConfigurationReview
    let title: String
    let subtitle: String?
    let controlWidth: CGFloat?
    let searchAnchorID: String?
    @ViewBuilder let trailing: Trailing

    init(
        configurationReview: SettingsConfigurationReview,
        _ title: String,
        subtitle: String? = nil,
        controlWidth: CGFloat? = nil,
        searchAnchorID: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        configurationReview.validate()
        self.configurationReview = configurationReview
        self.title = title
        self.subtitle = subtitle
        self.controlWidth = controlWidth
        self.searchAnchorID = searchAnchorID
        self.trailing = trailing()
    }

    private var searchAnchorIDs: [String] { searchAnchorID.map { [$0] } ?? configurationReview.searchAnchorIDs }

    var body: some View {
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
                    trailing
                        .frame(width: controlWidth, alignment: .trailing)
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
