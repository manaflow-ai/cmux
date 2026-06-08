#if os(iOS) && DEBUG
import CmuxMobileShell
import SwiftUI

/// The floating, hideable DEV dogfood pane: a draggable "bug" pill that expands
/// into an overlay card showing the agent-pushed checklist (each item a
/// multiple-choice question), a shared freeform note, and a Capture & Send
/// button.
///
/// Hosted in its own passthrough `UIWindow` (see ``DogfoodPaneWindowController``)
/// so it floats over the terminal regardless of the SwiftUI view tree. The whole
/// view is the only hittable content in that window; the rest is transparent and
/// passes touches through to the app.
///
/// DEV-only; not shipped, so its strings are not localized.
struct DogfoodPaneOverlayView: View {
    @Bindable var model: DogfoodFeedbackModel

    /// The pill's free-drag offset from its default bottom-trailing anchor.
    @State private var dragOffset: CGSize = .zero
    @State private var accumulatedOffset: CGSize = CGSize(width: -16, height: -120)

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                // Transparent backdrop: hit-tests off so taps fall through to the
                // app window beneath this overlay window.
                Color.clear
                    .allowsHitTesting(false)

                if model.isExpanded {
                    expandedCard
                        .frame(maxWidth: min(360, proxy.size.width - 24))
                        .padding(12)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                } else {
                    pill
                        .offset(currentOffset(in: proxy.size))
                        .gesture(dragGesture(in: proxy.size))
                }
            }
            .animation(.snappy(duration: 0.18), value: model.isExpanded)
        }
        .ignoresSafeArea()
    }

    // MARK: - Pill

    private var pill: some View {
        Button {
            model.toggleExpanded()
        } label: {
            Image(systemName: "ladybug.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.pink.opacity(0.9)))
                .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1))
                .shadow(radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("DogfoodPanePill")
    }

    /// The pill's hit-target size; also the basis for keeping it on-screen.
    private static let pillSize: CGFloat = 44
    /// Minimum on-screen inset so the pill never sits flush against an edge.
    private static let pillEdgeMargin: CGFloat = 8

    private func currentOffset(in size: CGSize) -> CGSize {
        clampedOffset(
            CGSize(
                width: accumulatedOffset.width + dragOffset.width,
                height: accumulatedOffset.height + dragOffset.height
            ),
            in: size
        )
    }

    /// Clamp an offset (relative to the bottom-trailing anchor) so the pill stays
    /// at least partially within the scene. The pill is the only affordance that
    /// reopens the overlay, so a long drag must not strand it off-screen with no
    /// hittable control left. Negative width moves left, negative height moves up.
    private func clampedOffset(_ offset: CGSize, in size: CGSize) -> CGSize {
        let minWidth = -max(0, size.width - Self.pillSize - Self.pillEdgeMargin)
        let minHeight = -max(0, size.height - Self.pillSize - Self.pillEdgeMargin)
        return CGSize(
            width: min(-Self.pillEdgeMargin, max(minWidth, offset.width)),
            height: min(-Self.pillEdgeMargin, max(minHeight, offset.height))
        )
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                // Persist the clamped offset so the pill cannot be lost off-screen.
                accumulatedOffset = clampedOffset(
                    CGSize(
                        width: accumulatedOffset.width + value.translation.width,
                        height: accumulatedOffset.height + value.translation.height
                    ),
                    in: size
                )
                dragOffset = .zero
            }
    }

    // MARK: - Expanded card

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            // Value-snapshot section so a note keystroke does not invalidate the
            // checklist rows (snapshot-boundary rule).
            DogfoodChecklistSection(
                items: model.checklist.items,
                selections: model.selections,
                select: { itemID, choice in model.selectAnswer(itemID: itemID, choice: choice) }
            )
            noteSection
            footer
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack {
            Label(model.checklist.title ?? "Dogfood", systemImage: "ladybug.fill")
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Button {
                model.toggleExpanded()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("DogfoodPaneCollapse")
        }
    }

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Note")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $model.note)
                .font(.callout)
                .frame(height: 64)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.12))
                )
                .accessibilityIdentifier("DogfoodPaneNote")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let succeeded = model.lastSubmitSucceeded {
                Label(
                    succeeded ? "Sent" : "Failed",
                    systemImage: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(succeeded ? Color.green : Color.orange)
            }
            Spacer()
            Button {
                Task { await model.captureAndSend() }
            } label: {
                HStack(spacing: 6) {
                    if model.isSubmitting {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.isSubmitting ? "Sending…" : "Capture & Send")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(model.isSubmitting)
            .accessibilityIdentifier("DogfoodPaneCaptureSend")
        }
    }
}
#endif
