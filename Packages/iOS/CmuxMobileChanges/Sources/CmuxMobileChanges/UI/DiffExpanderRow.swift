internal import Foundation
import SwiftUI

/// A wide GitHub-style control for revealing one hidden context run.
struct DiffExpanderRow: View {
    let snapshot: DiffExpanderSnapshot
    let status: DiffExpansionRowStatus
    let interactionDisabled: Bool
    let theme: ChangesTheme
    let onExpand: @MainActor @Sendable (DiffExpanderSnapshot, DiffExpansionDirection) -> Void

    /// Split up/down halves only when the two taps do different things; a run
    /// that fully reveals in one tap gets a single unified button.
    private var splitsDirections: Bool {
        snapshot.gap.directions.count > 1 && !snapshot.revealsCompletely
    }

    var body: some View {
        if splitsDirections || snapshot.gap.directions.count == 1 {
            band(directions: snapshot.gap.directions)
        } else {
            band(directions: [.down], unified: true)
        }
    }

    private func band(directions: [DiffExpansionDirection], unified: Bool = false) -> some View {
        HStack(spacing: 0) {
            ForEach(directions, id: \.self) { direction in
                Button {
                    onExpand(snapshot, direction)
                } label: {
                    HStack(spacing: 7) {
                        if isLoading(direction, unified: unified) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: glyph(direction, unified: unified))
                                .font(.caption.weight(.bold))
                        }
                        Text(visibleLabel(direction))
                            .font(.caption.weight(.medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(foregroundStyle(direction))
                .disabled(interactionDisabled || status == .tooLarge)
                .accessibilityLabel(unified ? unifiedAccessibilityLabel() : accessibilityLabel(direction))

                if direction != directions.last {
                    Rectangle()
                        .fill(theme.gutterSeparator)
                        .frame(width: 0.5, height: 30)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(theme.hunkHeaderBackground.opacity(0.72))
        .overlay {
            Rectangle()
                .stroke(theme.gutterSeparator, lineWidth: 0.5)
        }
    }

    private func isLoading(_ direction: DiffExpansionDirection, unified: Bool) -> Bool {
        unified
            ? status == .loading(.down) || status == .loading(.up)
            : status == .loading(direction)
    }

    private func glyph(_ direction: DiffExpansionDirection, unified: Bool) -> String {
        unified ? "arrow.up.and.down" : (direction == .up ? "chevron.up" : "chevron.down")
    }

    private func unifiedAccessibilityLabel() -> String {
        guard status != .tooLarge, let count = snapshot.expansionLineCount else {
            return visibleLabel(.down)
        }
        return String(
            format: String(
                localized: "changes.diff.expand.accessibility.all_count",
                defaultValue: "Expand all %lld hidden lines",
                bundle: .module
            ),
            Int64(count)
        )
    }

    private func visibleLabel(_ direction: DiffExpansionDirection) -> String {
        if status == .tooLarge {
            return String(
                localized: "changes.diff.expand.too_large",
                defaultValue: "Too large to expand",
                bundle: .module
            )
        }
        if status == .loading(direction) {
            return String(
                localized: "changes.diff.expand.loading",
                defaultValue: "Loading hidden lines…",
                bundle: .module
            )
        }
        if status == .failed(direction) {
            return String(
                localized: "changes.diff.expand.failed",
                defaultValue: "Couldn't expand lines. Tap to retry.",
                bundle: .module
            )
        }
        guard let count = snapshot.expansionLineCount else {
            return String(
                localized: "changes.diff.expand.hidden",
                defaultValue: "Expand hidden lines",
                bundle: .module
            )
        }
        return String(
            format: String(
                localized: "changes.diff.expand.count",
                defaultValue: "Expand %lld lines",
                bundle: .module
            ),
            Int64(count)
        )
    }

    private func accessibilityLabel(_ direction: DiffExpansionDirection) -> String {
        if status == .tooLarge {
            return visibleLabel(direction)
        }
        guard let count = snapshot.expansionLineCount else {
            switch direction {
            case .up:
                return String(
                    localized: "changes.diff.expand.accessibility.above",
                    defaultValue: "Expand hidden lines above",
                    bundle: .module
                )
            case .down:
                return String(
                    localized: "changes.diff.expand.accessibility.below",
                    defaultValue: "Expand hidden lines below",
                    bundle: .module
                )
            }
        }
        let format: String
        switch direction {
        case .up:
            format = String(
                localized: "changes.diff.expand.accessibility.above_count",
                defaultValue: "Expand %lld hidden lines above",
                bundle: .module
            )
        case .down:
            format = String(
                localized: "changes.diff.expand.accessibility.below_count",
                defaultValue: "Expand %lld hidden lines below",
                bundle: .module
            )
        }
        return String(format: format, Int64(count))
    }

    private func foregroundStyle(_ direction: DiffExpansionDirection) -> Color {
        if status == .tooLarge || status == .failed(direction) {
            return .secondary
        }
        return theme.hunkHeaderText
    }
}
