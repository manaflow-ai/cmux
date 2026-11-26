#if os(iOS)
import CmuxSpinner
import SwiftUI
import UIKit

private let theme = CmuxMobileTheme.standard

/// One empty or list-level failure state (SPEC 7.2, 7.3): symbol 28, title,
/// message, inline primary capsule, optional text CTA. Vertically centered.
public struct EmptyState: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey?
    let primaryTitle: LocalizedStringKey?
    let isPrimaryLoading: Bool
    let primary: (() -> Void)?
    let retry: (@MainActor () async -> Void)?
    let secondaryTitle: LocalizedStringKey?
    let secondary: (() -> Void)?

    public init(
        symbol: String,
        title: LocalizedStringKey,
        message: LocalizedStringKey? = nil,
        primaryTitle: LocalizedStringKey? = nil,
        isPrimaryLoading: Bool = false,
        primary: (() -> Void)? = nil,
        retry: (@MainActor () async -> Void)? = nil,
        secondaryTitle: LocalizedStringKey? = nil,
        secondary: (() -> Void)? = nil
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.primaryTitle = primaryTitle
        self.isPrimaryLoading = isPrimaryLoading
        self.primary = primary
        self.retry = retry
        self.secondaryTitle = secondaryTitle
        self.secondary = secondary
    }

    public var body: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(theme.colors.label)
                .accessibilityHidden(true)
            Text(title)
                .font(theme.type.emptyTitle)
                .foregroundStyle(theme.colors.label)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
            if let message {
                Text(message)
                    .font(theme.type.rowSubtitle)
                    .foregroundStyle(theme.colors.label2)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
            if let primaryTitle, let primary {
                PrimaryCapsule(primaryTitle, size: .inline, isLoading: isPrimaryLoading, action: primary)
                    .padding(.top, 20)
            }
            if let retry {
                RetryButton(action: retry).padding(.top, 20)
            }
            if let secondaryTitle, let secondary {
                TextCTA(secondaryTitle, action: secondary)
                    .padding(.top, primaryTitle == nil ? 20 : 12)
            }
        }
        .frame(maxWidth: 300)
        .padding(.horizontal, theme.metrics.sideMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The shimmer sweep (SPEC 7.1): a 30% band moving left to right every 1.6 s.
/// Static under Reduce Motion.
public struct ShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -0.3

    public init() {}

    public func body(content: Content) -> some View {
        content.overlay {
            if !reduceMotion {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, theme.colors.shimmerBand.color, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.3)
                    .offset(x: phase * proxy.size.width)
                }
                .mask(content)
                .onAppear {
                    withAnimation(.linear(duration: theme.motion.shimmerPeriod).repeatForever(autoreverses: false).unlessReduceMotion) {
                        phase = 1.0
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// Applies the skeleton shimmer.
    public func cmuxMobileShimmer() -> some View { modifier(ShimmerModifier()) }
}

/// Skeleton rows, shown only after `delay` (250 ms, so a fast load never
/// flashes; zero when the page's title is already drawn). Six rows max.
///
/// `.card` rows (title 60% x 14, subtitle 40% x 11, 60 pt, from the side
/// margin) stand in for card-like rows (Setup's teams). `.plainList` rows are
/// the plain lists' rows as they will draw (Workspaces): the bars start at the
/// list's text column (`CmuxMobileListColumn`), line 1 is a title with its time
/// trailing and line 2 a status line, each as tall as its text at the person's
/// Dynamic Type size, with the rows' 10 pt insets and their hairline, so the
/// rows that replace them land where the bars were (Leo, 2026-11-24: "i noticed
/// the skeleton for this was a bit off on ios").
///
/// The caption says what loads ("Loading workspaces…") as the rows' spoken
/// label; `captionPlacement` says whether it is also drawn, above the rows (it
/// pushed them down a line, so the rows that replace them jumped) or under them.
public struct SkeletonList: View {
    public enum Style: Equatable, Sendable {
        case card
        case plainList
    }

    public enum CaptionPlacement: Equatable, Sendable {
        /// Spoken only: the rows sit where the list's rows will.
        case spoken
        case above
        case below
    }

    let rows: Int
    let leadingSquare: CGFloat?
    let delay: Duration
    /// Says what loads ("Loading workspaces…"); nil keeps the plain "Loading".
    let caption: LocalizedStringKey?
    let style: Style
    let captionPlacement: CaptionPlacement
    @State private var isVisible = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var displayScale

    public init(rows: Int = 6, leadingSquare: CGFloat? = nil, delay: Duration = CmuxMobileTheme.standard.motion.skeletonDelay,
                caption: LocalizedStringKey? = nil, style: Style = .card, captionPlacement: CaptionPlacement = .above) {
        self.rows = min(rows, 6)
        self.leadingSquare = leadingSquare
        self.delay = delay
        self.caption = caption
        self.style = style
        self.captionPlacement = captionPlacement
    }

    /// Where a `.plainList` row's bars start: the list's text column.
    static func plainTextLeading(_ size: DynamicTypeSize) -> CGFloat { CmuxMobileListColumn.plain(size).text }
    /// Each `.plainList` row's insets, as the Workspaces cells' (`WorkspacesCollection.margins`).
    static let plainRowInsets = CmuxMobileListRowMetrics.insets
    /// A `.plainList` row's text block's least height (`WorkspaceRow`'s, with its status line).
    static let plainRowMinHeight = CmuxMobileListRowMetrics.minHeight
    /// The plain list's hairline ends this far from the trailing edge.
    static let plainSeparatorTrailing = CmuxMobileListRowMetrics.separatorTrailing
    /// Title widths, row by row, so the rows do not read as one repeated stamp.
    static let plainTitleWidths: [CGFloat] = [0.5, 0.62, 0.42, 0.56, 0.47, 0.6]
    static let plainStatusWidths: [CGFloat] = [0.72, 0.58, 0.66, 0.5, 0.7, 0.62]

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if captionPlacement == .above { captionText }
            ForEach(0..<rows, id: \.self) { index in
                switch style {
                case .card: cardRow
                case .plainList: plainRow(index)
                }
            }
            if captionPlacement == .below { captionText }
        }
        .cmuxMobileShimmer()
        .opacity(isVisible || delay == .zero ? 1 : 0)
        .task {
            guard delay > .zero else { return }
            try? await Task.sleep(for: delay)
            withAnimation(theme.motion.snap.animation.unlessReduceMotion) { isVisible = true }
        }
        .accessibilityElement()
        .accessibilityLabel(caption.map { Text($0) } ?? Text("Loading"))
    }

    @ViewBuilder private var captionText: some View {
        if let caption {
            Text(caption)
                .font(style == .plainList ? theme.type.meta : theme.type.rowSubtitle)
                .foregroundStyle(theme.colors.label2)
                .frame(maxWidth: .infinity, alignment: style == .plainList ? .leading : .center)
                .padding(.leading, style == .plainList ? Self.plainTextLeading(typeSize) : 0)
                .padding(.vertical, style == .plainList ? 10 : 12)
        }
    }

    private var cardRow: some View {
        HStack(spacing: 12) {
            if let leadingSquare {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.cmuxMobileContentFill(.inset))
                    .frame(width: leadingSquare, height: leadingSquare)
            }
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.cmuxMobileContentFill(.inset))
                        .frame(width: proxy.size.width * 0.6, height: 14)
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .fill(Color.cmuxMobileContentFill(.inset))
                        .frame(width: proxy.size.width * 0.4, height: 11)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(height: 60)
        .padding(.horizontal, theme.metrics.sideMargin)
    }

    /// One plain-list row: each line is its text's own line box (a hidden
    /// `Text` in the row's font) with a bar in it, so the row is as tall as
    /// the real one at every Dynamic Type size.
    private func plainRow(_ index: Int) -> some View {
        let leading = Self.plainTextLeading(typeSize)
        let insets = Self.plainRowInsets
        return GeometryReader { proxy in
            let width = max(0, proxy.size.width - leading - insets.trailing)
            VStack(alignment: .leading, spacing: CmuxMobileListRowMetrics.lineSpacing) {
                HStack(spacing: 8) {
                    bar(font: theme.type.rowTitle.weight(.semibold), fraction: 0.55,
                        width: width * Self.plainTitleWidths[index % Self.plainTitleWidths.count])
                    Spacer(minLength: 8)
                    bar(font: theme.type.meta, fraction: 0.6, width: 26)
                }
                bar(font: theme.type.meta, fraction: 0.6,
                    width: width * Self.plainStatusWidths[index % Self.plainStatusWidths.count])
            }
            .frame(width: width, alignment: .leading)
            .frame(minHeight: Self.plainRowMinHeight, alignment: .center)
            .padding(.top, insets.top)
            .padding(.leading, leading)
        }
        .frame(height: plainRowHeight)
        .overlay(alignment: .bottomLeading) {
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 1.0 / max(1, displayScale))
                .padding(.leading, leading)
                .padding(.trailing, Self.plainSeparatorTrailing)
        }
    }

    /// The row's height: its two lines (title, then status), at least
    /// `plainRowMinHeight`, plus its insets.
    private var plainRowHeight: CGFloat {
        let title = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).lineHeight
        let meta = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits).lineHeight
        return max(Self.plainRowMinHeight, ceil(title + 3 + meta)) + Self.plainRowInsets.top + Self.plainRowInsets.bottom
    }

    private var traits: UITraitCollection {
        UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
    }

    /// A bar as tall as `fraction` of a line of `font`, centered in that line's box.
    private func bar(font: Font, fraction: CGFloat, width: CGFloat) -> some View {
        Text(verbatim: "Ag")
            .font(font)
            .hidden()
            .frame(width: width, alignment: .leading)
            .overlay {
                GeometryReader { line in
                    let height = max(8, line.size.height * fraction)
                    RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                        .fill(Color.cmuxMobileContentFill(.inset))
                        .frame(width: width, height: height)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
            }
    }
}

/// Inline failure card (SPEC 7.3): `bg` with a 1 pt `separator` stroke, radius
/// 20, symbol + title + body, then a large primary capsule.
public struct FailureCard: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let actionTitle: LocalizedStringKey
    let isLoading: Bool
    let action: () -> Void

    public init(symbol: String = "exclamationmark.triangle", title: LocalizedStringKey, message: LocalizedStringKey, actionTitle: LocalizedStringKey = "Retry", isLoading: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.isLoading = isLoading
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 17))
                Text(title).font(theme.type.emptyTitle)
            }
            .foregroundStyle(theme.colors.label)
            Text(message).font(theme.type.rowSubtitle).foregroundStyle(theme.colors.label2)
            PrimaryCapsule(actionTitle, isLoading: isLoading, action: action)
                .padding(.top, 4)
        }
        .padding(16)
        .background(theme.colors.bg, in: .rect(cornerRadius: theme.metrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: theme.metrics.cardRadius, style: .continuous)
                .strokeBorder(theme.colors.separator, lineWidth: 1)
        }
    }
}

/// A transient toast (SPEC 7.4): glass capsule, optional symbol, 3 s.
public struct CmuxMobileToast: Sendable, Hashable, Identifiable {
    public let id = UUID()
    public let symbol: String?
    public let text: String

    public init(symbol: String? = nil, text: String) {
        self.symbol = symbol
        self.text = text
    }
}

extension View {
    /// Shows `state` under the top safe area, entering from y - 12, floating
    /// over the content: it takes no room, so the list under it never moves
    /// when it comes or goes (this replaces R2-4's inset, which pushed the
    /// list down). A link state (reconnecting, offline) is a ``ConnectionChip``
    /// a few words wide; a state with a sentence to read or an action (signed
    /// out, pairing) is the banner. A swipe up or sideways, or a tap, hides it
    /// until the state changes.
    public func cmuxMobileBanner(_ state: ConnectionBannerState?, retry: (() -> Void)? = nil) -> some View {
        // An overlay, not a safe-area inset: showing or hiding it moves nothing under it (Leo,
        // 2026-11-21: "these messages should not be pushing up the text ... stop layout
        // shifting"). A link state is a chip a few words wide, top center.
        overlay(alignment: .top) { BannerHost(state: state, retry: retry) }
    }

    /// Shows a toast under the top safe area for 3 s. One at a time; newest replaces.
    public func cmuxMobileToast(_ toast: Binding<CmuxMobileToast?>) -> some View {
        overlay(alignment: .top) { ToastHost(toast: toast) }
    }
}

/// The connection banner's slot: dismissible like every toast (`cmuxMobileDismissibleToast`); a
/// dismissed state stays hidden through the link's flaps (`BannerDismissal`).
private struct BannerHost: View {
    let state: ConnectionBannerState?
    let retry: (() -> Void)?
    @State private var dismissal: BannerDismissal?
    /// When the link went down (any chip state), kept across a change of state while down.
    @State private var downSince: Date?

    var body: some View {
        ZStack {
            // A link still trying shows nothing and announces nothing (``ConnectionBannerState/paints``).
            if let state, state.paints, state != dismissal?.state {
                Group {
                    if let chip = state.chip {
                        ConnectionChip(chip, downSince: downSince ?? ConnectionChip.justDropped, retry: state.offersRetry ? retry.map { action -> @MainActor () async -> Void in { action() } } : nil)
                            .placeholderBound("status.connection.chip", .milliseconds(0))
                    } else {
                        ConnectionBanner(state, retry: retry)
                    }
                }
                    .cmuxMobileDismissibleToast(entry: .top, announcement: state.text,
                                               tapDismisses: !(state.offersRetry && retry != nil)) {
                        withAnimation(theme.motion.snappy.animation.unlessReduceMotion) { dismissal = BannerDismissal(state: state) }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .offset(y: -12)))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(theme.motion.snappy.animation.unlessReduceMotion, value: state)
        .onChange(of: state) { _, new in dismissal = BannerDismissal.remembered(dismissal, after: new, at: .now) }
        .onChange(of: state?.chip != nil, initial: true) { _, down in
            downSince = ConnectionChip.nextDownSince(downSince, down: down, now: Date())
        }
    }
}

/// What a dismissed connection banner remembers: the state it hid, and since when there has been
/// no banner. A link that flaps (back for a moment, down again) brings the same state back: it
/// stays hidden (audit 20, ceremony: a dismissed "Reconnecting" came back on every flap). It shows
/// again only for a real new drop: another state (Offline, Signed out), or the same one after the
/// connection held for `flapWindow`.
struct BannerDismissal: Equatable {
    var state: ConnectionBannerState
    /// When the banner went away (the link came back); nil while the dismissed state lasts.
    var clearedAt: Date?

    /// How long the connection must hold before the same banner counts as a new drop.
    static let flapWindow: TimeInterval = 60

    /// The window as seen from the banner's return: a held state ("Reconnecting") comes back only
    /// after the quiet wait, so the drop it reports began that much earlier (review F1: without
    /// this, a connection that held 50 s read as one that held 60 s).
    static func window(for state: ConnectionBannerState) -> TimeInterval {
        guard state.showsSpinner else { return flapWindow }
        let quiet = QuietStatusGate.threshold.components
        return flapWindow + TimeInterval(quiet.seconds) + TimeInterval(quiet.attoseconds) / 1e18
    }

    static func remembered(_ dismissal: BannerDismissal?, after state: ConnectionBannerState?, at now: Date) -> BannerDismissal? {
        guard var dismissal else { return nil }
        guard let state else {
            // Back: remember when, so a flap right after keeps the banner hidden.
            if dismissal.clearedAt == nil { dismissal.clearedAt = now }
            return dismissal
        }
        guard state == dismissal.state else { return nil }
        if let cleared = dismissal.clearedAt, now.timeIntervalSince(cleared) >= window(for: state) { return nil }
        dismissal.clearedAt = nil
        return dismissal
    }
}

/// The toast overlay. It is a fileprivate type on purpose: SwiftUI's
/// `.task(id:)` is `@export(implementation)` with an availability-conditional
/// opaque return type, and with -O the default cross-module optimization
/// would serialize a public modifier that calls it into client modules, which
/// then reference the opaque type descriptor without emitting it (an
/// undefined symbol at link time). Code that references a fileprivate type
/// is never serialized, so the descriptor stays inside CmuxMobileDesign.
private struct ToastHost: View {
    @Binding var toast: CmuxMobileToast?

    var body: some View {
        ZStack {
            if let value = toast {
                HStack(spacing: 8) {
                    if let symbol = value.symbol { Image(systemName: symbol) }
                    Text(value.text)
                }
                .font(theme.type.meta.weight(.semibold))
                .foregroundStyle(theme.colors.label)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(minHeight: 36)
                .cmuxMobileFloatingGlass(in: .capsule)
                .padding(.top, 8)
                .transition(.opacity.combined(with: .offset(y: -12)))
                .id(value.id)
                .task(id: value.id) {
                    try? await Task.sleep(for: .seconds(3))
                    if toast?.id == value.id { toast = nil }
                }
                // Swipe up or sideways (it came from the top), or tap; VoiceOver: Dismiss.
                .cmuxMobileDismissibleToast(entry: .top, announcement: value.text) {
                    if toast?.id == value.id { toast = nil }
                }
            }
        }
        .animation(theme.motion.snappy.animation.unlessReduceMotion, value: toast)
    }
}

/// An 8 pt presence/status dot (SPEC 4.2).
public struct StatusDot: View {
    /// Dot state.
    public struct State: Sendable, Hashable {
        public let id: Int
        public static let online = State(id: 0)
        public static let offline = State(id: 1)
        public static let busy = State(id: 2)
        public static let error = State(id: 3)
    }

    let state: State
    var size: CGFloat

    public init(_ state: State, size: CGFloat = 8) {
        self.state = state
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .animation(theme.motion.snap.animation.unlessReduceMotion, value: state)
    }

    private var color: CmuxMobileColorToken {
        switch state {
        case .online: theme.colors.success
        case .busy: theme.colors.warning
        case .error: theme.colors.danger
        default: theme.colors.offline
        }
    }
}

/// Horizontal shake (SPEC 2.7 `shake`). Increment `trigger` to play.
public struct ShakeEffect: GeometryEffect {
    public var animatableData: CGFloat

    public init(trigger: Int) {
        animatableData = CGFloat(trigger)
    }

    public func effectValue(size: CGSize) -> ProjectionTransform {
        let offsets = CmuxMobileTheme.standard.motion.shakeOffsets
        let t = animatableData - animatableData.rounded(.down)
        guard t > 0 else { return ProjectionTransform(.identity) }
        let position = t * CGFloat(offsets.count - 1)
        let i = Int(position)
        let frac = position - CGFloat(i)
        let a = offsets[i], b = offsets[min(i + 1, offsets.count - 1)]
        return ProjectionTransform(CGAffineTransform(translationX: a + (b - a) * frac, y: 0))
    }
}
#endif
