#if os(iOS)
import SwiftUI
import UIKit

/// Chief's run while it works (Live frames v1), at the end of the transcript
/// just above the composer. It renders the protocol state only
/// (``ChiefSession/shownLive``):
/// - the reply text so far (`step.delta` talk), in an incoming bubble;
/// - one status line with the typing dots: the current step from
///   `run.activity`, else "Thinking…". It shows from the committed send (or
///   Chief's `conversation-typing`) until the run ends, so it is the typing
///   indicator before the first token and while the reply streams;
/// - tapping the line expands the run's details (thought text, tool and note
///   steps from `step.delta` thoughts and `conversation-run-changed` rows);
///   tapping again collapses them. Collapsed is the default.
/// The look is a placeholder: the final design comes from the gallery
/// prototypes, so every piece is a small view that is easy to restyle.
/// Drawn by the Chief screen over the transcript, outside
/// `ConversationStore`: the shared package has no ephemeral row.
struct ChiefLiveBubble: View {
    let session: ChiefSession
    /// Where the status line and details are, for the screen's hit test.
    var hitArea: ChiefLiveHitArea?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let live = session.shownLive {
                if let text = Self.replyText(live) {
                    Text(text)
                        .font(.body)
                        .foregroundStyle(.primary)
                        // The newest text: the head is cut, not the tail.
                        .lineLimit(8)
                        .truncationMode(.head)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color(uiColor: .systemGray5), in: .rect(cornerRadius: 18, style: .continuous))
                        .frame(maxWidth: 300, alignment: .leading)
                        .transition(.opacity)
                        .accessibilityIdentifier("chief.live.reply")
                }
                VStack(alignment: .leading, spacing: 6) {
                    ChiefLiveStatusLine(live: live, expanded: expanded, canExpand: !live.details.isEmpty) {
                        expanded.toggle()
                    }
                    if expanded, !live.details.isEmpty {
                        ChiefLiveDetails(details: live.details)
                            .transition(.opacity)
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { hitArea?.rect = $0 }
                .onDisappear { hitArea?.rect = .null }
            }
        }
        .frame(maxWidth: 328, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .animation(.easeOut(duration: 0.2), value: session.shownLive?.step)
        .animation(.easeOut(duration: 0.2), value: expanded)
        // A new run starts collapsed.
        .onChange(of: session.shownLive?.key) { expanded = false }
        .accessibilityIdentifier("chief.live.bubble")
    }

    static func replyText(_ live: ChiefLive) -> String? {
        let text = live.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return live.truncated ? "…" + text : text
    }

    /// The status line's text: the step the run is on, or "Thinking…".
    static func statusText(_ live: ChiefLive) -> String {
        if let line = live.activity?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty { return line }
        return String(localized: "Thinking…")
    }

    /// "Editing src/app.ts in sb-3 · 12s".
    static func activityLine(_ line: String, since: Date?, now: Date) -> String {
        guard let since else { return line }
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        let elapsed = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
        return "\(line) · \(elapsed)"
    }
}

/// The one-line status: typing dots, the shimmering step text with its
/// elapsed time, and a chevron when there are details to expand.
struct ChiefLiveStatusLine: View {
    let live: ChiefLive
    let expanded: Bool
    let canExpand: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                ChiefTypingDots()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ChiefShimmerText(text: ChiefLiveBubble.activityLine(ChiefLiveBubble.statusText(live), since: live.since, now: context.date))
                }
                if canExpand {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!canExpand)
        .accessibilityLabel(Text(ChiefLiveBubble.statusText(live)))
        .accessibilityHint(canExpand ? Text(expanded ? "Hides the details" : "Shows the details") : Text(""))
        .accessibilityIdentifier("chief.live.status")
    }
}

/// The run's thoughts and steps, oldest first, in a short scrolling list.
struct ChiefLiveDetails: View {
    let details: [ChiefLive.Detail]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(details) { detail in
                    ChiefLiveDetailRow(detail: detail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("chief.live.details")
    }
}

/// One detail: a thought's text, or a tool or note step.
struct ChiefLiveDetailRow: View {
    let detail: ChiefLive.Detail

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !detail.text.isEmpty {
                    Text(detail.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if detail.isRunning {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private var symbol: String {
        switch detail.kind {
        case .thought: "brain"
        case .tool: "wrench.and.screwdriver"
        case .note: "info.circle"
        }
    }

    private var title: String {
        switch detail.kind {
        case .thought: String(localized: "Thought")
        case .tool: detail.title.isEmpty ? String(localized: "Tool") : detail.title
        case .note: String(localized: "Note")
        }
    }
}

/// Text with a light band sweeping across it (no sweep with Reduce Motion).
struct ChiefShimmerText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let label = Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        if reduceMotion {
            label
        } else {
            label.overlay {
                // A band half the text wide whose middle runs from -0.25 to 1.25 of the width:
                // it enters and leaves fully off the text.
                // A repeating keyframe animation of the band's offset: it starts over whenever the
                // line appears, and only the band updates per frame.
                GeometryReader { proxy in
                    let width = proxy.size.width
                    LinearGradient(colors: [.clear, .white.opacity(0.7), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: width * 0.5)
                        .keyframeAnimator(initialValue: 0.0, repeating: true) { band, phase in
                            band.offset(x: -width * 0.5 + width * 1.5 * phase)
                        } keyframes: { _ in
                            LinearKeyframe(1.0, duration: 1.6)
                        }
                }
                .mask(label)
                .blendMode(.plusLighter)
            }
        }
    }
}

/// The three-dot typing indicator of the status line: a wave through the dots (each one's
/// opacity follows `sin(4t)`, a beat later than the one before), from a repeating keyframe
/// clock that starts over whenever the line appears. Still with Reduce Motion.
struct ChiefTypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One period of `sin(4t)`.
    static let period = Double.pi / 2

    var body: some View {
        Group {
            if reduceMotion {
                ChiefTypingDotsRow(t: nil)
            } else {
                ChiefTypingDotsRow(t: 0).keyframeAnimator(initialValue: 0.0, repeating: true) { _, t in
                    ChiefTypingDotsRow(t: t)
                } keyframes: { _ in
                    LinearKeyframe(Self.period, duration: Self.period)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Color(uiColor: .systemGray5), in: .capsule)
        .accessibilityHidden(true)
        .accessibilityIdentifier("chief.live.typing")
    }
}

/// The three dots at clock `t` (nil: still, Reduce Motion).
struct ChiefTypingDotsRow: View {
    let t: Double?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(t.map { 0.35 + 0.65 * max(0, sin($0 * 4 - Double(index) * 0.8)) } ?? 0.7)
            }
        }
    }
}

/// The window frame of the live status line and its details (the only
/// part of the overlay that takes touches).
@MainActor
final class ChiefLiveHitArea {
    var rect: CGRect = .null
}

/// Holds the live overlay: touches inside ``ChiefLiveHitArea`` reach it,
/// all others fall through to the transcript under it.
final class ChiefLivePassthroughView: UIView {
    let hitArea: ChiefLiveHitArea

    init(hitArea: ChiefLiveHitArea) {
        self.hitArea = hitArea
        super.init(frame: .zero)
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard !hitArea.rect.isNull else { return false }
        return hitArea.rect.insetBy(dx: -4, dy: -6).contains(convert(point, to: nil))
    }
}
#endif
