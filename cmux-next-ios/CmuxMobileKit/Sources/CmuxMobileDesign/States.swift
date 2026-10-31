#if os(iOS)
import SwiftUI

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
                    withAnimation(.linear(duration: theme.motion.shimmerPeriod).repeatForever(autoreverses: false)) {
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

/// Skeleton rows matching list row geometry (title 60% x 14, subtitle 40% x 11),
/// shown only after `delay` (250 ms, so a fast load never flashes; zero when
/// the page's title is already drawn). Six rows max.
public struct SkeletonList: View {
    let rows: Int
    let leadingSquare: CGFloat?
    let delay: Duration
    @State private var isVisible = false

    public init(rows: Int = 6, leadingSquare: CGFloat? = nil, delay: Duration = CmuxMobileTheme.standard.motion.skeletonDelay) {
        self.rows = min(rows, 6)
        self.leadingSquare = leadingSquare
        self.delay = delay
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: 12) {
                    if let leadingSquare {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.colors.surfaceRaised)
                            .frame(width: leadingSquare, height: leadingSquare)
                    }
                    GeometryReader { proxy in
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(theme.colors.surfaceRaised)
                                .frame(width: proxy.size.width * 0.6, height: 14)
                            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                .fill(theme.colors.surfaceRaised)
                                .frame(width: proxy.size.width * 0.4, height: 11)
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                }
                .frame(height: 60)
                .padding(.horizontal, theme.metrics.sideMargin)
            }
        }
        .cmuxMobileShimmer()
        .opacity(isVisible || delay == .zero ? 1 : 0)
        .task {
            guard delay > .zero else { return }
            try? await Task.sleep(for: delay)
            withAnimation(theme.motion.snap.animation) { isVisible = true }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Loading"))
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

/// The global connection banner states (SPEC 7.4).
public struct ConnectionBannerState: Sendable, Hashable {
    public let symbol: String?
    public let showsSpinner: Bool
    public let text: String
    /// A second line, smaller, for what to do next (pairing: where the Mac asks).
    public var detail: String? = nil
    public var offersRetry = false
    /// Stable identity so two Macs with the same state still refresh the banner.
    public var identity: String? = nil

    public static func reconnecting(to mac: String, identity: String? = nil) -> Self { Self(symbol: nil, showsSpinner: true, text: "Reconnecting…", identity: identity ?? mac) }
    public static let offline = Self(symbol: "wifi.slash", showsSpinner: false, text: "Offline", offersRetry: true)
    public static func macOffline(_ mac: String, identity: String? = nil) -> Self { Self(symbol: "moon.zzz", showsSpinner: false, text: "Offline", offersRetry: true, identity: identity ?? mac) }
    public static let connected = Self(symbol: "checkmark", showsSpinner: false, text: "Connected")
    public static func connecting(to mac: String, identity: String? = nil) -> Self { Self(symbol: nil, showsSpinner: true, text: "Reconnecting…", identity: identity ?? mac) }
    public static let connectionFailed = Self(symbol: "exclamationmark.triangle", showsSpinner: false, text: "Offline", offersRetry: true)
    /// An application failure distinct from connection state.
    public static func failed(_ text: String, identity: String? = nil) -> Self {
        Self(symbol: "exclamationmark.triangle", showsSpinner: false, text: text, identity: identity)
    }

    /// Gives a banner a stable owner without changing its copy. The owner keeps
    /// dismissal scoped to the Mac that produced the banner.
    public func identified(_ identity: String?) -> Self {
        var copy = self
        copy.identity = identity
        return copy
    }
    /// The Mac asks "Allow … to connect?" for this phone
    /// (verify/phone-approvals.md): a notification, a Dock bounce and
    /// Settings → Mobile on a Mac with #20491, only a cmux dialog on an older
    /// one. "Look for cmux" is true for both.
    public static func waitingForPairing(on mac: String, identity: String? = nil) -> Self {
        Self(symbol: "lock.shield", showsSpinner: true, text: String(localized: "Approve this iPhone on \(mac)"),
             detail: String(localized: "Look for cmux on your Mac"), identity: identity ?? mac)
    }
    /// The same after the phone replaced an unreadable stored key.
    public static func waitingForPairingAfterNewKeys(on mac: String, identity: String? = nil) -> Self {
        Self(symbol: "lock.shield", showsSpinner: true, text: String(localized: "Approve this iPhone again on \(mac)"),
             detail: String(localized: "Its keys were reset. Look for cmux on your Mac."), identity: identity ?? mac)
    }
}

/// Glass capsule banner, 36 pt tall, `footnote` semibold. Use `.cmuxMobileBanner(_:)`
/// to place it under the toolbar with the `snappy` enter/exit.
public struct ConnectionBanner: View {
    let state: ConnectionBannerState

    let retry: (() -> Void)?

    public init(_ state: ConnectionBannerState, retry: (() -> Void)? = nil) {
        self.state = state
        self.retry = retry
    }

    public var body: some View {
        HStack(spacing: 8) {
            if state.showsSpinner {
                ProgressView().controlSize(.small)
            } else if let symbol = state.symbol {
                Image(systemName: symbol)
            }
            if let detail = state.detail {
                // Two lines: what to do, then where (the Mac's notification).
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.text).lineLimit(3)
                    Text(detail)
                        .font(theme.type.meta)
                        .foregroundStyle(theme.colors.label2)
                        .lineLimit(3)
                }
                .fixedSize(horizontal: false, vertical: true)
                // A banner over the list: readable, never a wall of text.
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            } else {
                Text(state.text)
            }
            if state.offersRetry, let retry {
                Text("·").accessibilityHidden(true)
                Button("Retry", action: retry)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("connection.retry")
            }
        }
        .font(theme.type.meta.weight(.semibold))
        .foregroundStyle(theme.colors.label)
        .padding(.horizontal, state.detail == nil ? 14 : 16)
        .padding(.vertical, state.detail == nil ? 0 : 8)
        .frame(minHeight: 36)
        .glassEffect(.regular, in: .rect(cornerRadius: state.detail == nil ? 18 : 20, style: .continuous))
        .padding(.horizontal, 16)
        .accessibilityElement(children: state.offersRetry && retry != nil ? .contain : .combine)
        .accessibilityAddTraits(.updatesFrequently)
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
    /// Shows `state` as a banner under the top safe area, entering from
    /// y - 12. It takes its own room: the content below (a list) is inset
    /// by the banner's height at every text size, so it covers nothing (R2-4).
    /// A swipe up or sideways, or a tap, hides it until the state changes.
    public func cmuxMobileBanner(_ state: ConnectionBannerState?, retry: (() -> Void)? = nil) -> some View {
        safeAreaInset(edge: .top, spacing: 0) { BannerHost(state: state, retry: retry) }
    }

    /// Shows a toast under the top safe area for 3 s. One at a time; newest replaces.
    public func cmuxMobileToast(_ toast: Binding<CmuxMobileToast?>) -> some View {
        overlay(alignment: .top) { ToastHost(toast: toast) }
    }
}

/// The connection banner's slot: dismissible like every toast (`cmuxMobileDismissibleToast`); a
/// dismissed state stays hidden until the state changes (to no banner, or to another one).
private struct BannerHost: View {
    let state: ConnectionBannerState?
    let retry: (() -> Void)?
    @State private var dismissed: ConnectionBannerState?

    var body: some View {
        ZStack {
            if let state, state != dismissed {
                ConnectionBanner(state, retry: retry)
                    .cmuxMobileDismissibleToast(entry: .top, announcement: state.text,
                                               tapDismisses: !(state.offersRetry && retry != nil)) {
                        withAnimation(theme.motion.snappy.animation) { dismissed = state }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .offset(y: -12)))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(theme.motion.snappy.animation, value: state)
        .onChange(of: state) { _, new in dismissed = BannerDismissal.remembered(dismissed, after: new) }
    }
}

/// What a dismissed connection banner remembers: only the state it hid. Any other state, no banner
/// included, ends the dismissal, so the next episode of the same state shows again.
enum BannerDismissal {
    static func remembered(_ dismissed: ConnectionBannerState?, after state: ConnectionBannerState?) -> ConnectionBannerState? {
        state == dismissed ? dismissed : nil
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
                .frame(height: 36)
                .glassEffect(.regular, in: .capsule)
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
        .animation(theme.motion.snappy.animation, value: toast)
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
            .animation(theme.motion.snap.animation, value: state)
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
