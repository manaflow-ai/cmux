import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI
import UIKit

/// Live preview strip for one non-staged pane.
struct PaneRackStripView: View {
    let pane: PaneRackPaneSnapshot
    let paneIndex: Int
    let allPanes: [PaneRackPaneSnapshot]
    let tail: PaneTail?
    let chromeForeground: Color
    let background: Color
    let isMicro: Bool
    let stage: () -> Void
    let setPeekBudget: (Int) -> Void

    @GestureState private var isPeeking = false

    private var selectedTab: PaneRackTabSnapshot? { pane.selectedTab }
    private var restingHeight: CGFloat { isMicro ? 26 : 46 }

    var body: some View {
        ZStack(alignment: .leading) {
            background
                .overlay(Color.white.opacity(0.06))

            RoundedRectangle(cornerRadius: 1.5)
                .fill(selectedTab?.agentState.rackAccentColor ?? .clear)
                .frame(width: 3)

            if isPeeking {
                peekContent
            } else {
                stripContent
            }
        }
        .frame(height: isPeeking ? 240 : restingHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PlatformPalette.separator.opacity(0.25))
                .frame(height: 0.5)
        }
        .overlay {
            Color.clear
                .contentShape(Rectangle())
                .padding(.leading, 20)
                .gesture(activationGesture)
        }
        .clipped()
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: isPeeking)
        .onChange(of: isPeeking) { _, peeking in
            setPeekBudget(peeking ? 12 : 3)
            if peeking {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityTabCount)
        .accessibilityHint(
            L10n.string(
                "mobile.paneRack.strip.accessibilityHint",
                defaultValue: "Double-tap to focus. Touch and hold to peek."
            )
        )
        .accessibilityIdentifier("PaneRackStrip-\(pane.id)")
        .accessibilityAction { activate() }
    }

    private var stripContent: some View {
        HStack(spacing: 10) {
            PaneMiniGlyph(
                panes: allPanes,
                highlightedPaneID: pane.id,
                strokeColor: chromeForeground.opacity(0.35),
                fillColor: chromeForeground.opacity(0.8)
            )

            if isMicro {
                microTitle
            } else {
                standardTitle
                Spacer(minLength: 0)
                PaneRackPulseDot(
                    color: chromeForeground,
                    lastActivityAt: tail?.lastActivityAt
                )
            }
        }
        .padding(.leading, 15)
        .padding(.trailing, 12)
        .padding(.vertical, isMicro ? 0 : 6)
    }

    private var microTitle: some View {
        HStack(spacing: 5) {
            statusDot(size: 6)
            Text(selectedTab?.title ?? "")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(chromeForeground)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    private var standardTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                statusDot(size: 6)
                Text(selectedTab?.title ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(chromeForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if pane.tabs.count > 1 {
                    Text("\(pane.tabs.count)")
                        .font(.caption2)
                        .foregroundStyle(chromeForeground)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(chromeForeground.opacity(0.12), in: Capsule())
                }
            }
            Text(tail?.rows.last ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(chromeForeground.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var peekContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            stripContent
                .frame(height: 46)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array((tail?.rows.suffix(12) ?? []).enumerated()), id: \.offset) { _, row in
                    Text(row)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(chromeForeground.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 15)
            .padding(.bottom, 8)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func statusDot(size: CGFloat) -> some View {
        PaneRackStatusDot(
            color: selectedTab?.agentState.rackDotColor(chromeForeground: chromeForeground)
                ?? chromeForeground.opacity(0.3),
            size: size
        )
    }

    private var activationGesture: some Gesture {
        // A bare `LongPressGesture` reports `true` from touch-down and ends at
        // recognition, which would flash the peek open on every tap and snap
        // it shut at 0.35s while the finger is still holding. Sequencing a
        // zero-distance drag after recognition keeps `isPeeking` true for as
        // long as the finger stays down and resets it on release.
        TapGesture()
            .exclusively(
                before: LongPressGesture(minimumDuration: 0.35, maximumDistance: 12)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .updating($isPeeking) { value, state, _ in
                        if case .second = value { state = true }
                    }
            )
            .onEnded { result in
                guard case .first = result else { return }
                activate()
            }
    }

    private func activate() {
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
            stage()
        }
    }

    private var accessibilityLabel: String {
        String.localizedStringWithFormat(
            L10n.string(
                "mobile.paneRack.strip.accessibilityLabel",
                defaultValue: "Pane %1$d, %2$@, %3$@"
            ),
            paneIndex,
            selectedTab?.title ?? "",
            selectedTab?.agentState.localizedRackStatus ?? PaneRackAgentState.idle.localizedRackStatus
        )
    }

    private var accessibilityTabCount: String {
        guard pane.tabs.count > 1 else { return "" }
        return String.localizedStringWithFormat(
            L10n.string("mobile.paneRack.tabCount", defaultValue: "%d tabs"),
            pane.tabs.count
        )
    }
}
