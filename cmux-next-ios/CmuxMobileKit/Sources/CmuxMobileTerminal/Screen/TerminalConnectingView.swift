#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit

/// What a terminal page shows over its surface until the Mac's terminal is
/// attached: the page as last seen on this phone, as it was (never dimmed,
/// never covered), or, for a terminal never opened on this phone, a skeleton
/// of terminal lines with the shimmer (SPEC 7.1). Never made-up output, and
/// never a status pill over the content: the connection's state is the title
/// pill's subtitle, and only after ``QuietStatusGate/threshold``
/// (``TerminalModel/connectionLine``).
///
/// Leo, 2026-11-12, on LTE: "wack reconnection state / just show the cache".
public struct TerminalConnectingView: View {
    /// The status bar area over the page.
    let topInset: CGFloat
    /// The page as last seen (a tab coming back from the warm set, a cold
    /// launch, or a dropped link).
    let lastFrame: UIImage?
    /// Whether a page with no frame draws the skeleton (a warm surface that
    /// keeps its own live rows draws nothing over them).
    let showsPlaceholder: Bool
    /// The Mac's screen as text, as its `tabs` service last pushed it: drawn as it is (never
    /// dimmed) where there is no frame, for a tab not opened on this phone yet.
    let screenText: String?

    /// How far above this view's bottom edge the page's rows end now (the composer's top as it
    /// rests, keyboard up or down). Nil: the view does not know (a grid card), and draws a still
    /// as it was taken.
    let rowsLift: CGFloat?
    /// The still's rows (``TerminalFrameRows``) and whether they were measured yet.
    let rows: TerminalFrameRows?
    let rowsMeasured: Bool

    public init(topInset: CGFloat = 0, lastFrame: UIImage? = nil, showsPlaceholder: Bool = true,
                screenText: String? = nil,
                rowsLift: CGFloat? = nil, rows: TerminalFrameRows? = nil, rowsMeasured: Bool = true) {
        self.topInset = topInset
        self.lastFrame = lastFrame
        self.showsPlaceholder = showsPlaceholder
        self.screenText = screenText
        self.rowsLift = rowsLift
        self.rows = rows
        self.rowsMeasured = rowsMeasured
    }

    /// What the view draws: the cached frame wins; the skeleton only with no
    /// cache at all.
    enum Content: Equatable {
        case lastFrame
        case screenText
        case skeleton
        case nothing
    }

    /// Where a cover with no kept frame (the Mac's screen text or the skeleton) ends: the
    /// composer's top as it rests (`rowsLift` above the view's bottom), never below it.
    static func coverBottom(height: CGFloat, rowsLift: CGFloat?) -> CGFloat {
        max(0, height - max(0, rowsLift ?? 0))
    }

    static func content(hasLastFrame: Bool, showsPlaceholder: Bool, hasScreenText: Bool = false) -> Content {
        if hasLastFrame { return .lastFrame }
        // Only where the skeleton would be: a warm surface keeps its own live rows.
        if hasScreenText, showsPlaceholder { return .screenText }
        return showsPlaceholder ? .skeleton : .nothing
    }

    public var body: some View {
        ZStack(alignment: .top) {
            switch Self.content(hasLastFrame: lastFrame != nil, showsPlaceholder: showsPlaceholder,
                                hasScreenText: screenText?.isEmpty == false) {
            case .lastFrame:
                if let lastFrame {
                    GeometryReader { proxy in
                        if let rowsLift {
                            let rowsBottom = proxy.size.height - rowsLift
                            // Laid out for the page as it is now: the still's last row on the
                            // composer, nothing drawn over the composer or the key row (which
                            // take touches at once). Not drawn until its rows are measured
                            // (a frame or two), never at the place it was taken first.
                            if rowsMeasured {
                                let place = TerminalFramePlacement.make(pageWidth: proxy.size.width, imageSize: lastFrame.size,
                                                                        rows: rows, rowsBottom: min(rowsBottom, proxy.size.height))
                                Image(uiImage: lastFrame)
                                    .resizable()
                                    .interpolation(.medium)
                                    .frame(width: proxy.size.width, height: place.imageHeight)
                                    .offset(y: place.imageTop)
                                    .frame(width: proxy.size.width, height: max(0, place.clipBottom), alignment: .top)
                                    .clipped()
                                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                            }
                        } else {
                            Image(uiImage: lastFrame)
                                .resizable()
                                .interpolation(.medium)
                                .frame(width: proxy.size.width,
                                       height: proxy.size.width * lastFrame.size.height / max(1, lastFrame.size.width))
                                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                                .clipped()
                        }
                    }
                    .accessibilityHidden(true)
                    // R1: the page drawn from this phone's own frame cache (LaunchMarks.firstContent).
                    .onAppear { LaunchMarks.shared.firstContent("terminal", cached: true) }
                }
            case .screenText:
                GeometryReader { proxy in
                    // Not dimmed: a grayed-out page reads as one that takes no input (Leo,
                    // 2026-11-24: "the entire thing is somehow grayed out").
                    // Ends at the composer's top, as the skeleton and a kept frame do: the Mac's
                    // rows never run on under the composer bar (Aziz, 2026-11-26: "the loading
                    // terminal placeholder shouldnt leak under the composer bar").
                    let bottom = Self.coverBottom(height: proxy.size.height, rowsLift: rowsLift)
                    TerminalCardScreenText(text: screenText ?? "", topInset: topInset, width: proxy.size.width,
                                           visibleHeight: rowsLift == nil ? nil : bottom)
                        .frame(width: proxy.size.width, height: bottom, alignment: .top)
                        .clipped()
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                }
                .accessibilityHidden(true)
            case .skeleton:
                TerminalSkeleton(topInset: topInset, rowsLift: rowsLift)
            case .nothing:
                EmptyView()
            }
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier("terminal.connecting")
        .environment(\.colorScheme, .dark)
    }
}

/// The bound on a terminal page's connecting cover. A page whose Mac's rows never came drew the
/// skeleton's gray bars for good (Aziz's TestFlight build, 2026-11-25). Now the cover is a
/// skeleton only for ``bound``: past it, or at once when the session gave up or the Mac is
/// offline, the page says what is going on in words with Retry, and tries the attach again by
/// itself after each of ``retryDelays`` (the last one repeating) while the cover is up.
enum TerminalLoadWatch {
    /// How long the skeleton shows before the page offers Retry.
    static let bound: Duration = .seconds(8)
    /// The waits between the page's own retries of the attach, the first after ``bound``.
    static let retryDelays: [Duration] = [.seconds(8), .seconds(15), .seconds(30), .seconds(60)]

    /// The wait before the page's `attempt`th own retry (0 is the first).
    static func retryDelay(_ attempt: Int) -> Duration {
        retryDelays[min(max(0, attempt), retryDelays.count - 1)]
    }

    /// What the cover draws.
    enum Stage: Equatable {
        /// The skeleton (or the Mac's screen text): the rows are on their way.
        case loading
        /// Retry, with failure details only when the connection has failed or is offline.
        case stalled
    }

    static func stage(_ state: TerminalConnectionState, waited: Duration) -> Stage {
        switch state {
        case .attached:
            return .loading
        case .failed, .offline:
            return .stalled
        case .connecting, .reattaching:
            guard waited >= bound else { return .loading }
            return .stalled
        }
    }
}

/// The connecting cover past ``TerminalLoadWatch/bound``: what is going on and Retry, centered
/// on the page, in place of the skeleton.
public struct TerminalLoadStalledPanel: View {
    let state: TerminalConnectionState
    /// The link's own status line for the Mac (``TerminalModel/linkStatus``): a network that
    /// blocks the link says so there, and that is the reason shown, over the generic words.
    let linkStatus: String?
    let retry: @MainActor () async -> Void

    public init(state: TerminalConnectionState, linkStatus: String? = nil, retry: @escaping @MainActor () async -> Void) {
        self.state = state
        self.linkStatus = linkStatus
        self.retry = retry
    }

    /// Keep failure copy with the action that resolves it; an ongoing attach has no notice.
    static func notice(_ state: TerminalConnectionState, linkStatus: String? = nil) -> (title: String, detail: String)? {
        // "Offline" alone repeats the title: the generic reason stays.
        let status = linkStatus.flatMap { $0.isEmpty || $0 == "Offline" ? nil : $0 }
        switch state {
        case .failed:
            return ("Can't reach this terminal", status ?? "Check that the Mac is on and cmux is open.")
        case .offline:
            return (state.quietLine ?? "Your Mac is offline", status ?? "The terminal opens when it is back.")
        case .attached, .connecting, .reattaching:
            return nil
        }
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.6))
                .accessibilityHidden(true)
            if let notice = Self.notice(state, linkStatus: linkStatus) {
                Text(verbatim: notice.title)
                    .font(.headline)
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.center)
                Text(verbatim: notice.detail)
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            RetryButton(action: retry)
                .accessibilityIdentifier("terminal.connecting.retry")
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.connecting.stalled")
        .environment(\.colorScheme, .dark)
    }
}

/// A terminal never opened on this phone, until its Mac's rows arrive: the shape of a
/// terminal (SPEC 7.1), not a list of grey bars. Rows at the terminal's own line pitch, a
/// prompt's `$` at each command line's start, output lines of uneven length, and the last
/// row a prompt with the cursor block, resting on the composer as the live rows do. The
/// shimmer runs over the text, never over the prompt's cursor.
struct TerminalSkeleton: View {
    let topInset: CGFloat
    let rowsLift: CGFloat?

    /// One row: a command line (the prompt's `$` then a command) or output, as fractions of
    /// the width. Oldest first; the newest row (the live prompt) is drawn after them.
    enum Row: Equatable {
        case command(CGFloat)
        case output(CGFloat)
    }

    static let rows: [Row] = [
        .command(0.34), .output(0.82), .output(0.66), .output(0.74), .output(0.4),
        .command(0.46), .output(0.9), .output(0.58), .output(0.0), .command(0.28), .output(0.7), .output(0.52),
    ]

    static let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static var pitch: CGFloat { ceil(font.lineHeight) + 2 }
    static let barHeight: CGFloat = 9
    static let inset: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let pitch = Self.pitch
            let bottom = TerminalConnectingView.coverBottom(height: proxy.size.height, rowsLift: rowsLift)
            // As many of the rows as fit between the top bar and the composer, newest last.
            let room = max(0, Int((bottom - topInset - 8) / pitch) - 1)
            let shown = Array(Self.rows.suffix(room))
            let textWidth = proxy.size.width - 2 * Self.inset
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, row in
                        line(row, width: textWidth)
                    }
                }
                .cmuxMobileShimmer()
                prompt
            }
            .padding(.horizontal, Self.inset)
            .frame(width: proxy.size.width, height: max(0, bottom - 4), alignment: .bottomLeading)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func line(_ row: Row, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            switch row {
            case .command(let fraction):
                Text("$").font(Font(Self.font)).foregroundStyle(Color.white.opacity(0.28))
                bar(width: width * fraction, opacity: 0.14)
            case .output(let fraction):
                bar(width: width * fraction, opacity: 0.08)
            }
        }
        .frame(height: Self.pitch, alignment: .leading)
    }

    private func bar(width: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.white.opacity(opacity))
            .frame(width: max(0, width), height: Self.barHeight)
    }

    /// The live prompt: `$` and the cursor block, where the shell's prompt will be.
    private var prompt: some View {
        HStack(spacing: 6) {
            Text("$").font(Font(Self.font)).foregroundStyle(Color.white.opacity(0.4))
            Rectangle().fill(Color.white.opacity(0.55)).frame(width: 8, height: ceil(Self.font.lineHeight) - 2)
        }
        .frame(height: Self.pitch, alignment: .leading)
    }
}
#endif
