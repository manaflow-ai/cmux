#if os(iOS)
import CmuxMobileDesign
import SwiftUI

/// SPEC 4.5: label2 text with a highlight band sweeping left to right (1.6 s), elapsed time after 5 s.
public struct WorkingLabel: View {
    let text: String
    var since: Date?
    var font: Font
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ text: String = "Working", since: Date? = nil, font: Font = .body) {
        self.text = text
        self.since = since
        self.font = font
    }

    public var body: some View {
        HStack(spacing: 6) {
            Shimmer(active: !reduceMotion) {
                Text(text).font(font)
            }
            if let since {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    let elapsed = Int(context.date.timeIntervalSince(since))
                    if elapsed >= 5 {
                        Text("· \(elapsed < 60 ? "\(elapsed)s" : "\(elapsed / 60)m \(elapsed % 60)s")")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .contentTransition(.numericText())
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Text shimmer: label2 base, a 40% band of label sweeping across every 1.6 s. The band's
/// offset is a repeating keyframe animation: it starts from its first frame whenever the
/// label appears (a reused cell, a row that scrolls back), and only the band's offset updates
/// per frame (a `TimelineView(.animation)` re-ran the whole label). A `repeatForever` started
/// from `onAppear` could be cancelled by the same update and leave the band still.
struct Shimmer<Content: View>: View {
    let active: Bool
    @ViewBuilder let content: Content

    var body: some View {
        if active {
            content
                .foregroundStyle(.secondary)
                .overlay {
                    content
                        .foregroundStyle(.primary)
                        .mask {
                            GeometryReader { proxy in
                                let width = proxy.size.width
                                LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: max(width * 0.4, 30))
                                    .keyframeAnimator(initialValue: 0.0, repeating: true) { band, phase in
                                        band.offset(x: -width * 0.4 + width * 1.4 * phase)
                                    } keyframes: { _ in
                                        LinearKeyframe(1.0, duration: 1.6)
                                    }
                            }
                        }
                        .accessibilityHidden(true)
                }
        } else {
            content.foregroundStyle(.secondary)
        }
    }
}
#endif
