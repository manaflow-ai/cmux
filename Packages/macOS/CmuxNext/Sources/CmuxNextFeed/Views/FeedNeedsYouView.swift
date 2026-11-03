public import AppKit
public import CmuxNextDesign
import SwiftUI

/// How the pinned Needs you section draws (`feed.needsYouStyle`, Debug Settings > Feed). Rows is
/// the default; the others are its gallery variants, switched live.
public nonisolated enum FeedNeedsYouStyle: String, Sendable, CaseIterable, TunableChoice {
    /// One line per request: what it is, who asked, and its one-click answers at the end.
    case rows
    /// The Feed list's own request cards (what it asks, then its answers under it).
    case cards
    /// One line for all of them: the count and the first request; a click opens it.
    case bar

    public var tunableTitle: String {
        switch self {
        case .rows: "Rows (answers at the end)"
        case .cards: "Cards (the Feed's request cards)"
        case .bar: "One line (count and first request)"
        }
    }
}

extension FeedModel {
    /// What waits on the person: the Feed's open requests, the items and the order its list pins at
    /// its top (``listSections``), read from this model (no second store).
    public var needsYou: [FeedItem] { listSections.requests }
}

/// The Feed's open requests as a pinned section (Chief Home's Needs you): each request says what
/// it is and who asked; a click on it opens its source (``onOpen``); the answers the Feed's own row
/// offers in one click answer through the Feed's own path (``FeedAnswerControls``). Past ``limit``
/// requests the rest are counted, and the count opens the Feed (``onShowAll``). It draws nothing
/// when nothing waits; the host removes it then. It observes the model only while it is drawn, and
/// owns no timer.
public final class FeedNeedsYouView: NSView {
    public let model: FeedModel
    /// The look; nil follows ``FeedTunables/needsYouStyle``.
    public let style: FeedNeedsYouStyle?
    /// The most requests listed; the rest are counted.
    public let limit: Int
    /// A click on a request (not on one of its answers): the host opens its source.
    public var onOpen: (FeedItem) -> Void = { _ in }
    /// A click on the count of the requests not listed: the host opens the Feed.
    public var onShowAll: () -> Void = {}
    /// The section's height changed (a request came or went, an answer form opened).
    public var onHeightChange: () -> Void = {}
    private let palette = FeedAppearance()
    private var hosting: FeedNeedsYouHost?

    public init(model: FeedModel, style: FeedNeedsYouStyle? = nil, limit: Int = 3) {
        self.model = model
        self.style = style
        self.limit = max(1, limit)
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
        setAccessibilityIdentifier("cmux.home.needsYou")
        let root = FeedNeedsYouSection(model: model, style: style, limit: self.limit, appearance: palette,
                                       open: { [weak self] item in self?.onOpen(item) }, showAll: { [weak self] in self?.onShowAll() })
        let hosting = FeedNeedsYouHost(rootView: root)
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.onResize = { [weak self] in self?.onHeightChange() }
        self.hosting = hosting
        embed(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The requests listed, in the Feed's order.
    public var shownIDs: [String] { Self.split(model.needsYou, limit: limit).shown.map(\.id) }
    /// The requests past ``limit``, counted under the list.
    public var moreCount: Int { Self.split(model.needsYou, limit: limit).more }
    /// Nothing waits: the section draws nothing.
    public var isEmpty: Bool { model.needsYou.isEmpty }
    /// The height its content needs.
    public var preferredHeight: CGFloat { isEmpty ? 0 : ceil(hosting?.fittingSize.height ?? 0) }

    /// The requests listed and how many more there are.
    nonisolated static func split(_ requests: [FeedItem], limit: Int) -> (shown: [FeedItem], more: Int) {
        (Array(requests.prefix(limit)), max(0, requests.count - limit))
    }

    /// The answers a request's row offers in place: the ones the Feed row answers with a click.
    /// A question or a choice needs typing or picking: its row opens it instead.
    nonisolated static func answersInline(_ item: FeedItem) -> Bool {
        switch item.prompt {
        case .notice, .question, .choice: false
        case .approve, .confirm, .signIn, .passkey, .review, .handoff, .file, .input, .custom: true
        }
    }

    nonisolated public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() { resolveColors() }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveColors()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }

    private func resolveColors() {
        let colors = performWithTheme { FeedColors.resolved(background: Palette.elevatedBackground) }
        if palette.colors != colors { palette.colors = colors }
    }
}

/// Tells the section when its content resized, so the host lays it out again.
final class FeedNeedsYouHost: NSHostingView<FeedNeedsYouSection> {
    var onResize: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onResize?()
    }
}

struct FeedNeedsYouSection: View {
    let model: FeedModel
    let style: FeedNeedsYouStyle?
    let limit: Int
    let appearance: FeedAppearance
    let open: (FeedItem) -> Void
    let showAll: () -> Void

    var body: some View {
        let requests = model.needsYou
        let colors = appearance.colors
        Group {
            if !requests.isEmpty {
                switch style ?? FeedTunables.needsYouStyle.value {
                case .rows: list(requests, colors: colors) { FeedNeedsYouRow(item: $0, model: model, open: open) }
                // The Feed's own card: its Open, Sign In and answer buttons act; no tap over them.
                case .cards: list(requests, colors: colors) { FeedRequestCard(item: $0, model: model) }
                case .bar: FeedNeedsYouBar(requests: requests, model: model, open: open, showAll: showAll)
                }
            }
        }
        .background(card(colors, empty: requests.isEmpty))
        .environment(\.feedColors, colors)
        .tint(colors.primary)
    }

    /// The title, the listed requests, and the count of the rest.
    private func list<Row: View>(_ requests: [FeedItem], colors: FeedColors, row: @escaping (FeedItem) -> Row) -> some View {
        let (shown, more) = FeedNeedsYouView.split(requests, limit: limit)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(FeedStrings.needsYou).font(.system(size: TypeScale.caption, weight: .semibold)).foregroundStyle(colors.secondary)
                Text(verbatim: "\(requests.count)").font(.system(size: TypeScale.caption)).monospacedDigit().foregroundStyle(colors.tertiary)
                Spacer(minLength: 0)
                if more > 0 {
                    Button(FeedStrings.needsYouMore(more), action: showAll)
                        .buttonStyle(FeedButtonStyle(role: .plain, compact: true))
                        .accessibilityIdentifier("cmux.home.needsYou.more")
                }
            }
            .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 2)
            ForEach(shown, id: \.id) { row($0) }
        }
        .padding(6)
    }

    @ViewBuilder
    private func card(_ colors: FeedColors, empty: Bool) -> some View {
        if !empty {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(colors.elevated)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(colors.borders ? colors.separator : .clear, lineWidth: 1))
                .shadow(color: colors.shadow, radius: 8, y: 2)
        }
    }
}

/// One request: what it is and who asked (a click opens its source), then its one-click answers.
struct FeedNeedsYouRow: View {
    let item: FeedItem
    let model: FeedModel
    let open: (FeedItem) -> Void
    @Environment(\.feedColors) private var colors
    @State private var hovering = false

    var body: some View {
        let content = FeedRowContent(item: item, place: model.place?(item))
        HStack(alignment: .center, spacing: 8) {
            Button { open(item) } label: {
                HStack(spacing: 8) {
                    FeedGlyph(item: item)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(content.headline)
                            .font(.system(size: TypeScale.body, weight: .semibold))
                            .foregroundStyle(colors.primary)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Text(content.meta.isEmpty ? item.poster.displayLabel : content.meta).lineLimit(1)
                            Text(verbatim: "·")
                            Text(FeedRelativeTime.string(item.createdAt, now: model.now)).monospacedDigit()
                        }
                        .font(.system(size: TypeScale.caption))
                        .foregroundStyle(colors.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? colors.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel(content.accessibilityLabel)
            .accessibilityIdentifier("cmux.home.needsYou.row")
            if FeedNeedsYouView.answersInline(item) {
                FeedAnswerControls(item: item, model: model, density: .inline).fixedSize()
            }
        }
        .padding(.trailing, 4)
        .opacity(model.isPending(item.id) ? 0.55 : 1)
    }
}

/// Variant `bar`: "Needs you 3 · Allow make build?" on one line; a click opens the only request,
/// or the Feed when there are more.
struct FeedNeedsYouBar: View {
    let requests: [FeedItem]
    let model: FeedModel
    let open: (FeedItem) -> Void
    let showAll: () -> Void
    @Environment(\.feedColors) private var colors
    @State private var hovering = false

    var body: some View {
        let first = requests[0]
        Button { requests.count == 1 ? open(first) : showAll() } label: {
            HStack(spacing: 8) {
                FeedGlyph(item: first)
                Text(FeedStrings.needsYou).font(.system(size: TypeScale.body, weight: .semibold)).foregroundStyle(colors.primary)
                Text(verbatim: "\(requests.count)").font(.system(size: TypeScale.body)).monospacedDigit().foregroundStyle(colors.secondary)
                Text(verbatim: "·").foregroundStyle(colors.tertiary)
                Text(FeedRowContent.lines(first).headline).lineLimit(1).foregroundStyle(colors.secondary)
                Spacer(minLength: 0)
            }
            .font(.system(size: TypeScale.body))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? colors.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("cmux.home.needsYou.bar")
    }
}
