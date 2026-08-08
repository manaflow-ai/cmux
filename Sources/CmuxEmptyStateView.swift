import CmuxFoundation
import SwiftUI

/// Shared empty-state presentation for cmux surfaces that have nothing to
/// show yet.
///
/// Reproduces the metrics and hierarchy of AppKit's
/// `ContentUnavailableView` — large tinted glyph, short title, one line of
/// guidance, then the actions that resolve the state — but renders through
/// ``CmuxSystemSymbolImage`` and `cmuxFont` so the glyph and the type both
/// follow the user's global font magnification. `ContentUnavailableView`
/// styles its own labels with unmagnified system fonts, so it would ignore
/// that setting.
///
/// The body is wrapped in a `ViewThatFits` ladder so the same call site
/// works in a full-window pane and in a narrow split: the glyph is dropped
/// first, then the description, rather than clipping the actions the user
/// needs to press.
///
/// ```swift
/// CmuxEmptyStateView(
///     symbolName: "terminal",
///     title: String(localized: "emptyPanel.title", defaultValue: "Nothing open here")
/// ) {
///     Button("New Terminal") { createTerminal() }
/// }
/// ```
@MainActor
struct CmuxEmptyStateView<Actions: View>: View {
    /// SF Symbol drawn above the title, tinted with the tertiary style.
    let symbolName: String
    /// Short sentence-case statement of what is missing.
    let title: String
    /// Optional single line explaining how to fill the surface.
    let description: String?
    /// Controls that resolve the empty state, laid out in a centered row.
    @ViewBuilder let actions: Actions

    /// Creates an empty state.
    ///
    /// - Parameters:
    ///   - symbolName: SF Symbol name for the glyph.
    ///   - title: Short statement of what is missing.
    ///   - description: Optional guidance line; omit when the title says enough.
    ///   - actions: Buttons that resolve the state. Pass `EmptyView()` for none.
    init(
        symbolName: String,
        title: String,
        description: String? = nil,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.symbolName = symbolName
        self.title = title
        self.description = description
        self.actions = actions()
    }

    var body: some View {
        // Widest layout first: ViewThatFits picks the first child whose
        // ideal size fits, so the glyph and description degrade in that
        // order and the actions row always survives.
        ViewThatFits(in: .vertical) {
            stack(showsSymbol: true, showsDescription: true)
            stack(showsSymbol: false, showsDescription: true)
            stack(showsSymbol: false, showsDescription: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
        // The glyph repeats the title, and the title is already read as the
        // heading, so the image would only add noise for VoiceOver.
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func stack(showsSymbol: Bool, showsDescription: Bool) -> some View {
        VStack(spacing: 0) {
            if showsSymbol {
                CmuxSystemSymbolImage(magnified: symbolName, pointSize: 38)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                    .padding(.bottom, 12)
            }

            VStack(spacing: 0) {
                Text(title)
                    .cmuxFont(.title3, weight: .semibold)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                if showsDescription, let description {
                    Text(description)
                        .cmuxFont(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
            // Clamp only the text column, to roughly the measure AppKit
            // gives ContentUnavailableView: a long description wraps into a
            // readable block instead of one edge-to-edge line. The actions
            // row is deliberately outside this clamp — constraining it too
            // would push a pair of normal-width buttons into the stacked
            // fallback even on a wide pane.
            .frame(maxWidth: 360)
            .fixedSize(horizontal: false, vertical: true)

            actionsRow
        }
    }

    @ViewBuilder
    private var actionsRow: some View {
        // `Actions` is EmptyView when the caller passes no buttons; the
        // Group still lays out, so gate the top padding on the type to
        // avoid a stray 16pt gap under the last line of text.
        if Actions.self != EmptyView.self {
            // A single row reads best, but the Dock and Feed panels are
            // narrow enough that three buttons would run past the edge.
            // Fall back to a column rather than truncating a button title.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions }
                VStack(spacing: 8) { actions }
            }
            .padding(.top, 16)
        }
    }
}
