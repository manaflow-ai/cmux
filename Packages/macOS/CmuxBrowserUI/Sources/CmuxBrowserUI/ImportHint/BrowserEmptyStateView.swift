public import CmuxBrowser
public import SwiftUI

/// The browser blank-tab empty-state chrome that frames the import-hint body in
/// one of two placements: a centered floating card or a top inline strip.
///
/// The placement is decided app-side from
/// ``BrowserImportHintBlankTabPlacement`` and forwarded here; the app-side
/// overlay gating ensures only `.floatingCard` and `.inlineStrip` reach this
/// view (other placements render nothing). Renders a ``BrowserImportHintView``
/// from the same ``BrowserImportHintSnapshot``/``BrowserImportHintActions``, so
/// every mutation stays on the app-side forwarder.
public struct BrowserEmptyStateView: View {
    private let placement: BrowserImportHintBlankTabPlacement
    private let snapshot: BrowserImportHintSnapshot
    private let actions: BrowserImportHintActions

    /// Creates the empty-state chrome for the given blank-tab placement.
    public init(
        placement: BrowserImportHintBlankTabPlacement,
        snapshot: BrowserImportHintSnapshot,
        actions: BrowserImportHintActions
    ) {
        self.placement = placement
        self.snapshot = snapshot
        self.actions = actions
    }

    public var body: some View {
        switch placement {
        case .floatingCard:
            cardOverlay
        case .inlineStrip:
            inlineStrip
        case .hidden, .toolbarChip:
            EmptyView()
        }
    }

    private var cardOverlay: some View {
        VStack {
            Spacer(minLength: 22)

            BrowserImportHintView(snapshot: snapshot, actions: actions)
            .padding(12)
            .frame(maxWidth: 360, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(
                    Color(nsColor: .separatorColor).opacity(0.45),
                    lineWidth: 1
                )
            )
            .shadow(color: Color.black.opacity(0.08), radius: 8, y: 3)

            Spacer()
        }
        .padding(.horizontal, 18)
    }

    private var inlineStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrowserImportHintView(snapshot: snapshot, actions: actions)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: 520, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.84))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(
                        Color(nsColor: .separatorColor).opacity(0.35),
                        lineWidth: 1
                    )
                )
                .shadow(color: Color.black.opacity(0.05), radius: 6, y: 2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }
}
