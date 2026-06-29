import CmuxAgentChat
import CmuxMobileSupport
import SwiftUI

/// The compact toolbar-principal header: a leading state indicator beside a
/// two-line title (workspace name over tab name).
///
/// State is carried entirely by the indicator (color + motion + a symbol for
/// the two "attention" states), not words, so the narrow nav-bar center can
/// spend its width on the names rather than on "needs input ·". VoiceOver
/// still hears the full state via the accessibility value.
public struct ChatSessionHeaderView: View {
    public enum Style: Sendable {
        case regular
        case toolbarCompact
    }

    private let descriptor: ChatSessionDescriptor
    private let agentState: ChatAgentState
    private let isConnected: Bool
    private let titleOverride: String?
    private let subtitle: String?
    private let style: Style

    /// Creates a session header.
    ///
    /// - Parameters:
    ///   - descriptor: The session identity (title, agent kind).
    ///   - agentState: Live agent presence, driving the indicator.
    ///   - isConnected: Whether the live event stream is up; when `false`
    ///     the indicator desaturates and breathes (reconnecting).
    ///   - titleOverride: When set, shown as the headline instead of the
    ///     session's generated title (the host passes the workspace name so
    ///     the header reads as the workspace, not the first prompt).
    ///   - subtitle: When set, shown as line two (the host passes the
    ///     tab/terminal name).
    public init(
        descriptor: ChatSessionDescriptor,
        agentState: ChatAgentState,
        isConnected: Bool,
        titleOverride: String? = nil,
        subtitle: String? = nil,
        style: Style = .regular
    ) {
        self.descriptor = descriptor
        self.agentState = agentState
        self.isConnected = isConnected
        self.titleOverride = titleOverride
        self.subtitle = subtitle
        self.style = style
    }

    public var body: some View {
        HStack(spacing: 6) {
            ChatStateIndicatorView(state: agentState, isConnected: isConnected, size: indicatorSize)
            titleStack
        }
        .padding(.horizontal, horizontalContentPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    private var title: String {
        titleOverride ?? descriptor.title ?? descriptor.agentKind.displayName
    }

    private var subtitleLine: String? {
        guard let subtitle, !subtitle.isEmpty else { return nil }
        return subtitle
    }

    @ViewBuilder
    private var titleStack: some View {
        switch style {
        case .regular:
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitleLine {
                    Text(subtitleLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        case .toolbarCompact:
            MobileCompactToolbarTitleStack(title: title, subtitle: subtitleLine)
        }
    }

    private var indicatorSize: CGFloat {
        switch style {
        case .regular:
            return 11
        case .toolbarCompact:
            return 10
        }
    }

    private var horizontalContentPadding: CGFloat {
        switch style {
        case .regular:
            return 0
        case .toolbarCompact:
            return MobileCompactToolbarTitleMetrics.horizontalContentPadding
        }
    }

    /// VoiceOver reads the names; the live state is the accessibility value.
    private var accessibilityLabel: String {
        guard let subtitleLine else { return title }
        return "\(title), \(subtitleLine)"
    }

    private var accessibilityValue: String {
        var value = stateLabel
        if !isConnected {
            value += ", "
            value += String(
                localized: "chat.header.reconnecting",
                defaultValue: "reconnecting…",
                bundle: .module
            )
        }
        return value
    }

    private var stateLabel: String {
        switch agentState {
        case .working:
            return String(
                localized: "chat.header.state.working", defaultValue: "working", bundle: .module
            )
        case .needsInput:
            return String(
                localized: "chat.header.state.needs_input",
                defaultValue: "needs input",
                bundle: .module
            )
        case .idle:
            return String(
                localized: "chat.header.state.idle", defaultValue: "idle", bundle: .module
            )
        case .ended:
            return String(
                localized: "chat.header.state.ended", defaultValue: "ended", bundle: .module
            )
        }
    }
}

/// The header's state glyph: color + motion for the two ambient states
/// (working pulses green, idle is a filled gray dot), and a distinct SF
/// Symbol shape for the two meaningful ones (needs-input is an orange
/// question mark, ended is a hollow ring) so the four states are
/// distinguishable by shape and motion, not color alone. While
/// reconnecting it desaturates and breathes regardless of state.
struct ChatStateIndicatorView: View {
    let state: ChatAgentState
    let isConnected: Bool
    let size: CGFloat

    @State private var pulseDimmed = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isWorking: Bool {
        if case .working = state { return true }
        return false
    }

    /// Pulses while working; breathes (slower) while reconnecting.
    private var pulses: Bool {
        (isWorking || !isConnected) && !reduceMotion
    }

    var body: some View {
        glyph
            .frame(width: size, height: size)
            .saturation(isConnected ? 1 : 0)
            .opacity(opacity)
            .animation(
                pulses
                    ? .easeInOut(duration: isConnected ? 0.9 : 1.4).repeatForever(autoreverses: true)
                    : .default,
                value: pulseDimmed
            )
            // Drive the pulse from `pulses` itself (not a one-shot onAppear),
            // so it starts on idle->working and STOPS on working->idle even
            // though this header view is reused across state changes.
            .onAppear { pulseDimmed = pulses }
            .onChange(of: pulses) { _, on in pulseDimmed = on }
            .accessibilityHidden(true)
    }

    private var opacity: Double {
        if pulses { return pulseDimmed ? 0.4 : 1.0 }
        return isConnected ? 1 : 0.6
    }

    @ViewBuilder
    private var glyph: some View {
        switch state {
        case .working:
            Circle().fill(Color.green)
        case .idle:
            Circle().fill(Color.secondary)
        case .needsInput:
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(.white, .orange)
        case .ended:
            Circle().stroke(Color.secondary, lineWidth: 1.3)
        }
    }
}
