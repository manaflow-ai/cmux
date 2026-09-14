import AppKit
import SwiftUI

/// Renders one Cloud tree section header and its optional contextual action.
struct CloudTreeGroupRowContent: View {
    let title: String
    let count: Int?
    let style: CloudTreeStyle
    let helpAction: (@MainActor (NSWindow?) -> Void)?
    var showsHelp = true

    var body: some View {
        HStack(alignment: .center, spacing: style.iconGap) {
            HStack(alignment: .firstTextBaseline, spacing: CloudTreeRowGrid.detailGap) {
                Text(style.groupLabelStyle == .uppercased ? title.uppercased() : title)
                    .tracking(style.groupLabelStyle == .uppercased ? 0.8 : 0)
                    .cmuxFont(size: style.groupLabelSize, weight: .medium, design: style.fontDesign)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if style.showsGroupCounts, let count {
                    Text(String(count))
                        .cmuxFont(size: style.detailSize, design: style.fontDesign, monospacedDigit: true)
                        .foregroundStyle(.tertiary)
                }
            }
            if showsHelp, let helpAction {
                CloudVPNSetupButtonRepresentable(setup: helpAction)
                    .frame(width: 28, height: 24)
                    .accessibilitySortPriority(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, CloudTreeRowGrid.trailingPadding)
    }
}
