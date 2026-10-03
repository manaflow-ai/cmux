import CmuxFoundation
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
///
/// Use ``verticalAlignment`` and ``trailingFillsWidth`` for a tall editor
/// that should keep its title pinned to the top while giving the editor the
/// remaining horizontal space.
///
/// - Parameter verticalAlignment: Controls how the title and trailing content
///   align vertically.
/// - Parameter trailingFillsWidth: Gives the trailing content all remaining
///   horizontal space when `true`.
@MainActor
public struct SettingsCardRow<Trailing: View>: View {
    let configurationReview: SettingsConfigurationReview
    let title: String
    let subtitle: String?
    let controlWidth: CGFloat?
    let verticalAlignment: VerticalAlignment
    let trailingFillsWidth: Bool
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
        verticalAlignment: VerticalAlignment = .center,
        trailingFillsWidth: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.configurationReview = configurationReview
        self.searchAnchorID = searchAnchorID
        self.title = title
        self.subtitle = subtitle
        self.controlWidth = controlWidth
        self.verticalAlignment = verticalAlignment
        self.trailingFillsWidth = trailingFillsWidth
        self.trailing = trailing()
    }

    public var body: some View {
        SettingsCardRowLayout(
            verticalAlignment: verticalAlignment,
            trailingFillsWidth: trailingFillsWidth
        ) {
            VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 3) {
                Text(title)
                    .cmuxFont(size: 13, weight: .medium)
                if let subtitle {
                    Text(subtitle)
                        .cmuxFont(.caption)
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
            .frame(
                maxWidth: trailingFillsWidth ? .infinity : nil,
                alignment: .leading
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsSearchAnchors(searchAnchorIDs)
    }
}

/// Places a card row's title and control side by side, or stacks the control
/// under the title when the row is too narrow for both. Settings can render in
/// a narrow workspace pane, and a side-by-side row wider than its card pushed
/// the whole page past the pane's edge. One layout with the same two subviews
/// (not `ViewThatFits`) keeps each control's identity and state when the pane
/// is resized across the threshold.
struct SettingsCardRowLayout: Layout {
    let verticalAlignment: VerticalAlignment
    let trailingFillsWidth: Bool
    var spacing: CGFloat = 12
    var stackedSpacing: CGFloat = 8
    /// Title width a row keeps beside its control before it stacks.
    static let minimumTitleWidth: CGFloat = 160

    private struct Arrangement {
        let isStacked: Bool
        let titleWidth: CGFloat
        let controlWidth: CGFloat
    }

    private func arrangement(width: CGFloat?, subviews: Subviews) -> Arrangement {
        let title = subviews[0]
        let control = subviews[1]
        let titleIdeal = title.sizeThatFits(.unspecified).width
        let controlIdeal = control.sizeThatFits(.unspecified).width
        let controlMinimum = control.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width
        guard let width, width.isFinite else {
            return Arrangement(isStacked: false, titleWidth: titleIdeal, controlWidth: controlIdeal)
        }
        let titleComfort = min(titleIdeal, Self.minimumTitleWidth)
        let controlNeed = trailingFillsWidth ? controlMinimum : controlIdeal
        if controlNeed + spacing + titleComfort > width {
            let controlWidth = trailingFillsWidth ? width : min(controlIdeal, width)
            return Arrangement(isStacked: true, titleWidth: width, controlWidth: max(controlWidth, controlMinimum))
        }
        let controlWidth = trailingFillsWidth ? width - spacing - titleComfort : controlIdeal
        return Arrangement(isStacked: false, titleWidth: width - spacing - controlWidth, controlWidth: controlWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let layout = arrangement(width: proposal.width, subviews: subviews)
        let titleHeight = subviews[0].sizeThatFits(ProposedViewSize(width: layout.titleWidth, height: nil)).height
        let controlHeight = subviews[1].sizeThatFits(ProposedViewSize(width: layout.controlWidth, height: nil)).height
        if layout.isStacked {
            return CGSize(
                width: max(layout.titleWidth, layout.controlWidth),
                height: titleHeight + stackedSpacing + controlHeight
            )
        }
        return CGSize(
            width: layout.titleWidth + spacing + layout.controlWidth,
            height: max(titleHeight, controlHeight)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let layout = arrangement(width: bounds.width, subviews: subviews)
        let titleProposal = ProposedViewSize(width: layout.titleWidth, height: nil)
        let controlProposal = ProposedViewSize(width: layout.controlWidth, height: nil)
        let titleHeight = subviews[0].sizeThatFits(titleProposal).height
        let controlHeight = subviews[1].sizeThatFits(controlProposal).height
        if layout.isStacked {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading, proposal: titleProposal)
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + titleHeight + stackedSpacing),
                anchor: .topLeading,
                proposal: controlProposal
            )
            return
        }
        func originY(_ height: CGFloat) -> CGFloat {
            switch verticalAlignment {
            case .top: return bounds.minY
            case .bottom: return bounds.maxY - height
            default: return bounds.midY - height / 2
            }
        }
        subviews[0].place(at: CGPoint(x: bounds.minX, y: originY(titleHeight)), anchor: .topLeading, proposal: titleProposal)
        subviews[1].place(
            at: CGPoint(x: bounds.maxX - layout.controlWidth, y: originY(controlHeight)),
            anchor: .topLeading,
            proposal: controlProposal
        )
    }
}
