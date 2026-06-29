import CmuxAgentChat
import CmuxMobileSupport
import SwiftUI

/// The horizontal shortcut row above the composer field.
public struct ChatAccessoryChipRow: View {
    private static let scrollEdgeBlurWidth: CGFloat = 34

    private let agentState: ChatAgentState
    private let leadingShortcuts: [ChatAccessoryShortcut]
    private let shortcuts: [ChatAccessoryShortcut]
    private let onInterrupt: (Bool) -> Void
    private let onOpenTerminal: () -> Void

    @State private var scrollContentWidth: CGFloat = 0
    @State private var scrollViewportWidth: CGFloat = 0

    /// Creates the chip row.
    ///
    /// - Parameters:
    ///   - agentState: Live agent presence; working adds the Stop chip.
    ///   - leadingShortcuts: Host-provided fixed buttons shown before the
    ///     horizontally scrollable shortcut region.
    ///   - shortcuts: Host-provided scrollable shortcut buttons. When both
    ///     host-provided arrays are empty, the row uses the legacy chat-only
    ///     Esc/Ctrl-C/Terminal shortcuts.
    ///   - onInterrupt: Interrupts the agent (`false` = Esc, `true` =
    ///     Ctrl-C).
    ///   - onOpenTerminal: Opens the session's raw terminal.
    public init(
        agentState: ChatAgentState,
        leadingShortcuts: [ChatAccessoryShortcut] = [],
        shortcuts: [ChatAccessoryShortcut] = [],
        onInterrupt: @escaping (Bool) -> Void,
        onOpenTerminal: @escaping () -> Void
    ) {
        self.agentState = agentState
        self.leadingShortcuts = leadingShortcuts
        self.shortcuts = shortcuts
        self.onInterrupt = onInterrupt
        self.onOpenTerminal = onOpenTerminal
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(displayedLeadingShortcuts) { shortcut in
                chip(shortcut)
            }

            if !displayedScrollableShortcuts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(displayedScrollableShortcuts) { shortcut in
                            chip(shortcut)
                        }
                    }
                    // Inset the row content slightly so the fade reveals/clips
                    // chips rather than cropping the very first/last chip flush
                    // at the edge.
                    .padding(.horizontal, 2)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                        scrollContentWidth = width
                    }
                }
                .frame(height: 32)
                .layoutPriority(1)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                    scrollViewportWidth = width
                }
                .overlay(alignment: .leading) {
                    if scrollNeedsEdgeBlur {
                        scrollEdgeBlur(isLeading: true)
                    }
                }
                .overlay(alignment: .trailing) {
                    if scrollNeedsEdgeBlur {
                        scrollEdgeBlur(isLeading: false)
                    }
                }
            }
        }
        .frame(height: 32)
    }

    private var displayedLeadingShortcuts: [ChatAccessoryShortcut] {
        guard usesHostShortcuts else { return [] }
        var resolved = leadingShortcuts
        if isWorking {
            resolved.insert(stopShortcut, at: 0)
        }
        return resolved
    }

    private var displayedScrollableShortcuts: [ChatAccessoryShortcut] {
        if usesHostShortcuts {
            return shortcuts
        }
        var resolved = legacyShortcuts
        if isWorking {
            resolved.insert(stopShortcut, at: 0)
        }
        return resolved
    }

    private var usesHostShortcuts: Bool {
        !leadingShortcuts.isEmpty || !shortcuts.isEmpty
    }

    private var scrollNeedsEdgeBlur: Bool {
        scrollContentWidth > scrollViewportWidth + 1
    }

    private var stopShortcut: ChatAccessoryShortcut {
        ChatAccessoryShortcut(
            id: "chat.chip.stop",
            title: String(localized: "chat.chip.stop", defaultValue: "Stop", bundle: .module),
            tint: .red
        ) {
            onInterrupt(false)
        }
    }

    private var isWorking: Bool {
        if case .working = agentState { return true }
        return false
    }

    private var legacyShortcuts: [ChatAccessoryShortcut] {
        [
            ChatAccessoryShortcut(
                id: "chat.chip.esc",
                title: String(localized: "chat.chip.esc", defaultValue: "Esc", bundle: .module)
            ) {
                onInterrupt(false)
            },
            ChatAccessoryShortcut(
                id: "chat.chip.ctrl_c",
                title: String(localized: "chat.chip.ctrl_c", defaultValue: "Ctrl-C", bundle: .module)
            ) {
                onInterrupt(true)
            },
            ChatAccessoryShortcut(
                id: "chat.chip.terminal",
                title: String(localized: "chat.chip.terminal", defaultValue: "Terminal", bundle: .module),
                action: onOpenTerminal
            ),
        ]
    }

    private func chip(_ shortcut: ChatAccessoryShortcut) -> some View {
        Button(action: shortcut.perform) {
            chipContent(shortcut)
                .font(.footnote)
                .foregroundStyle(shortcut.tint ?? .primary)
                .padding(.horizontal, shortcut.systemImage == nil ? 12 : 8)
                .frame(minWidth: 32)
                .frame(height: 32)
                #if os(iOS)
                .mobileGlassPill()
                #else
                .background(
                    (shortcut.tint?.opacity(0.12) ?? Color.secondary.opacity(0.15)),
                    in: .capsule
                )
                #endif
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(shortcut.id)
        .accessibilityLabel(shortcut.accessibilityLabel ?? shortcut.title)
    }

    @ViewBuilder
    private func chipContent(_ shortcut: ChatAccessoryShortcut) -> some View {
        if let systemImage = shortcut.systemImage {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
        } else {
            Text(shortcut.title)
        }
    }

    private func scrollEdgeBlur(isLeading: Bool) -> some View {
        Rectangle()
            .fill(.regularMaterial)
            .frame(width: Self.scrollEdgeBlurWidth)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: isLeading ? .black : .clear, location: 0),
                        .init(color: isLeading ? .black : .clear, location: 0.18),
                        .init(color: isLeading ? .clear : .black, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .allowsHitTesting(false)
    }
}
