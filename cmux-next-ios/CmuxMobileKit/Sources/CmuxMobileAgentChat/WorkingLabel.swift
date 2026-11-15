#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import os
import SwiftUI

/// SPEC 4.5: label2 text with a highlight band sweeping left to right (1.6 s), elapsed time after 5 s.
public struct WorkingLabel: View {
    let text: String
    var since: Date?
    var font: Font
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Between `onAppear` and `onDisappear`: the elapsed time ticks only then.
    @State private var shown = true

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
                // Ticks only while it can be seen: its row on screen (a row scrolled away stays
                // alive in the list's reuse pool) and the app not in the background.
                TimelineView(Self.elapsedSchedule(since: since, live: shown && MinuteClock.shared.isActive)) { context in
                    let _ = Self.noteRedraw(since: since)
                    // The time of this redraw, or now if later: when the label is seen again its
                    // schedule starts over, and it shows the current time at once.
                    if let elapsed = Self.elapsedText(since: since, at: max(context.date, Date())) {
                        Text(elapsed)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .contentTransition(.numericText())
                    }
                }
                .onAppear { shown = true }
                .onDisappear { shown = false }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The time after the label at `date`: nothing for the first 5 s, then "· 12s", "· 1m 5s".
    static func elapsedText(since: Date, at date: Date) -> String? {
        let elapsed = Int(date.timeIntervalSince(since))
        guard elapsed >= 5 else { return nil }
        return "· \(elapsed < 60 ? "\(elapsed)s" : "\(elapsed / 60)m \(elapsed % 60)s")"
    }

    /// When the elapsed time redraws: when the row appears, then each second from 5 s on
    /// (before that the text is nothing, and a redraw would draw nothing again).
    /// Not `live`: only the moment it is asked, then nothing.
    static func elapsedSchedule(since: Date, live: Bool = true) -> ElapsedTextSchedule {
        ElapsedTextSchedule(since: since, quietSeconds: 5, live: live)
    }

    /// DEBUG and Demo: in the list rig's running chat (`CMUX_MOBILE_LIST_HOLD_TURN=1`), one
    /// `FRAMELOG list-stress label-tick` line per redraw of the time; the energy bench counts
    /// them, so it shows whether the time still redraws off screen or in the background.
    @MainActor static func noteRedraw(since: Date) {
        #if DEBUG
        if let counted = redrawCounts[since] { redrawCounts[since] = counted + 1 }
        if ListStressSettings.shared.logsLabelTicks { tickLog.notice("FRAMELOG list-stress label-tick") }
        #endif
    }

    #if DEBUG
    private static let tickLog = Logger(subsystem: "dev.cmux.mobile", category: "frames")
    /// DEBUG, for tests: the redraws of the time of each label whose start a test put here (as 0).
    @MainActor static var redrawCounts: [Date: Int] = [:]
    #endif
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
