import CmuxAgentChat
import SwiftUI

/// The compact toolbar-principal header: session title over a one-line
/// status (colored state dot, state text, reconnect suffix).
public struct ChatSessionHeaderView: View {
    private let descriptor: ChatSessionDescriptor
    private let agentState: ChatAgentState
    private let isConnected: Bool
    private let titleOverride: String?
    private let subtitle: String?

    /// Creates a session header.
    ///
    /// - Parameters:
    ///   - descriptor: The session identity (title, agent kind).
    ///   - agentState: Live agent presence, driving the dot and text.
    ///   - isConnected: Whether the live event stream is up; when `false`
    ///     a reconnecting suffix is appended.
    ///   - titleOverride: When set, shown as the headline instead of the
    ///     session's generated title (the host passes the workspace name so
    ///     the header reads as the workspace, not the first prompt).
    ///   - subtitle: When set, appended to the status line after the state
    ///     (the host passes the tab/terminal name).
    public init(
        descriptor: ChatSessionDescriptor,
        agentState: ChatAgentState,
        isConnected: Bool,
        titleOverride: String? = nil,
        subtitle: String? = nil
    ) {
        self.descriptor = descriptor
        self.agentState = agentState
        self.isConnected = isConnected
        self.titleOverride = titleOverride
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(spacing: 1) {
            Text(titleOverride ?? descriptor.title ?? descriptor.agentKind.displayName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 4) {
                ChatStateDotView(color: dotColor, pulses: isWorking)
                Text(statusLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var isWorking: Bool {
        if case .working = agentState { return true }
        return false
    }

    private var dotColor: Color {
        switch agentState {
        case .working: return .green
        case .needsInput: return .orange
        case .idle: return .gray
        case .ended: return .red
        }
    }

    private var statusLine: String {
        var line = stateLabel
        if let subtitle, !subtitle.isEmpty {
            line += " · "
            line += subtitle
        }
        if !isConnected {
            line += " · "
            line += String(
                localized: "chat.header.reconnecting",
                defaultValue: "reconnecting…",
                bundle: .module
            )
        }
        return line
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

/// The header's small status dot, with a subtle pulse while working.
struct ChatStateDotView: View {
    let color: Color
    let pulses: Bool

    @State private var pulsing = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(!reduceMotion && pulses && pulsing ? 0.45 : 1)
            .animation(
                pulses && !reduceMotion
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .default,
                value: pulsing
            )
            .onAppear { pulsing = true }
            .accessibilityHidden(true)
    }
}
