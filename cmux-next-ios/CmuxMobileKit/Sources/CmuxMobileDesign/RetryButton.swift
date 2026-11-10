#if os(iOS)
import CmuxSpinner
import SwiftUI

/// The shared recovery action. Its work belongs to the visible control and is
/// cancelled when it leaves the screen; repeated taps cannot overlap a load.
///
/// `.capsule` (the default) is the SPEC 4.1 inline secondary capsule: 40 pt
/// tall in a 44 pt target, 20 pt side padding, `cta` type, always wider than
/// tall, so a short title like "Retry" never collapses into a circle.
/// `.inline` is a plain semibold text action for a row, pill or banner that
/// already draws its own background (a capsule inside a capsule reads as a
/// stray circle).
public struct RetryButton: View {
    /// How the button is drawn.
    public enum Style: Sendable, Hashable {
        /// A standalone secondary capsule (empty states, failure cards).
        case capsule
        /// Plain text inside a container that already has a background.
        case inline
    }

    let title: Text?
    let style: Style
    let action: @MainActor () async -> Void
    @State private var isRetrying = false
    @State private var taps = 0

    /// `title` defaults to "Retry"; pass the surface's own wording ("Try Again").
    public init(_ title: LocalizedStringKey? = nil, style: Style = .capsule, action: @escaping @MainActor () async -> Void) {
        self.title = title.map { Text($0) }
        self.style = style
        self.action = action
    }

    private var titleText: Text { title ?? Text(verbatim: Self.defaultTitle) }

    /// The default title: "Retry".
    public static var defaultTitle: String {
        String(localized: "recovery.retry", defaultValue: "Retry", bundle: .module)
    }

    /// Once shown, the spinner stays at least this long: a load that answers in a
    /// frame or two otherwise flashes it (and the press) as a flicker.
    public static let minimumSpin: Duration = .milliseconds(450)

    public var body: some View {
        styled(Button {
            guard !isRetrying else { return }
            taps += 1
            isRetrying = true
        } label: {
            // The title keeps its place and width while loading; the spinner replaces it
            // in place, so the capsule never resizes and nothing around it moves. The
            // capsule keeps its colors too: no disabled-state color flash on the tap.
            titleText
                .opacity(isRetrying ? 0 : 1)
                .overlay {
                    if isRetrying {
                        CmuxSpinner(tint: Color(uiColor: .label))
                            .controlSize(.small)
                            .transition(.opacity.combined(with: .scale(scale: 0.6)))
                            .accessibilityHidden(true)
                    }
                }
                .animation(CmuxMobileTheme.standard.motion.snap.animation.unlessReduceMotion, value: isRetrying)
        })
        // Repeated taps cannot overlap a load; not `.disabled`, which would swap the colors.
        .allowsHitTesting(!isRetrying)
        // The hidden title still names the button for VoiceOver while it loads.
        .accessibilityLabel(titleText)
        .accessibilityAddTraits(isRetrying ? .updatesFrequently : [])
        .cmuxMobileSensoryFeedback(.impact(weight: .light), trigger: taps)
        .task(id: isRetrying) {
            guard isRetrying else { return }
            await Self.run(action, holdingFor: Self.minimumSpin, on: ContinuousClock())
            isRetrying = false
        }
    }

    /// Runs `action`, then holds until `minimum` has passed since it started, so a
    /// fast answer reads as a load, not a flicker. A cancelled hold ends at once.
    public static func run<C: Clock<Duration>>(_ action: @MainActor () async -> Void, holdingFor minimum: Duration,
                                        on clock: C) async {
        let started = clock.now
        await action()
        try? await clock.sleep(until: started.advanced(by: minimum), tolerance: nil)
    }

    @ViewBuilder
    private func styled(_ button: some View) -> some View {
        switch style {
        case .capsule:
            button.buttonStyle(CmuxMobileCapsuleButtonStyle(.secondary, size: .inline))
        case .inline:
            button
                .buttonStyle(.plain)
                .font(CmuxMobileTheme.standard.type.meta.weight(.semibold))
                .foregroundStyle(CmuxMobileTheme.standard.colors.label)
                .frame(minHeight: CmuxMobileTheme.standard.metrics.glassButton)
                .contentShape(.rect)
        }
    }
}
/// Short recovery copy shared by the Home surfaces.
public enum RecoveryMessage {
    case home, conversation

    public var text: String {
        switch self {
        case .home: String(localized: "recovery.home", defaultValue: "Couldn't load this Mac's Home.", bundle: .module)
        case .conversation: String(localized: "recovery.conversation", defaultValue: "Couldn't load this conversation.", bundle: .module)
        }
    }
}
#endif
