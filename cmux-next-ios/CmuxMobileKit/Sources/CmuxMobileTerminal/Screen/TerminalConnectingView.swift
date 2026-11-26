#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit

/// What a terminal page shows over its surface until the Mac's terminal is
/// attached: the page as last seen on this phone, as it was (never dimmed,
/// never covered), or, with no saved copy at all, nothing during the quiet
/// bound and then which Mac cannot be reached, why, and Retry
/// (``TerminalUnreachable``; Leo, 2026-11-25: "the placeholder's also bad",
/// which retired the skeleton of fake `$` rows). Never made-up output, and
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
    /// A page with no saved copy, past the quiet bound: which Mac, why, and Retry (nil: nothing).
    let unreachable: TerminalUnreachable?
    let retry: (@MainActor () async -> Void)?

    public init(topInset: CGFloat = 0, lastFrame: UIImage? = nil, showsPlaceholder: Bool = true,
                screenText: String? = nil,
                rowsLift: CGFloat? = nil, rows: TerminalFrameRows? = nil, rowsMeasured: Bool = true,
                unreachable: TerminalUnreachable? = nil, retry: (@MainActor () async -> Void)? = nil) {
        self.unreachable = unreachable
        self.retry = retry
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
        /// No saved copy: nothing faked; past the quiet bound, ``TerminalUnreachable``.
        case unreachable
        case nothing
    }

    static func content(hasLastFrame: Bool, showsPlaceholder: Bool, hasScreenText: Bool = false) -> Content {
        if hasLastFrame { return .lastFrame }
        // Only where the skeleton would be: a warm surface keeps its own live rows.
        if hasScreenText, showsPlaceholder { return .screenText }
        return showsPlaceholder ? .unreachable : .nothing
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
                    .allowsHitTesting(false)
                }
            case .screenText:
                GeometryReader { proxy in
                    // Not dimmed: a grayed-out page reads as one that takes no input (Leo,
                    // 2026-11-24: "the entire thing is somehow grayed out").
                    TerminalCardScreenText(text: screenText ?? "", topInset: topInset, width: proxy.size.width)
                }
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            case .unreachable:
                if let unreachable {
                    TerminalUnreachableView(state: unreachable, retry: retry)
                        .padding(.top, topInset)
                        .padding(.bottom, rowsLift ?? 0)
                }
            case .nothing:
                EmptyView()
            }
        }
        .accessibilityIdentifier("terminal.connecting")
        .environment(\.colorScheme, .dark)
    }
}

/// What a page with no saved copy at all says once its outage passed the quiet bound: which Mac
/// cannot be reached, why in plain words, and Retry. Replaces the skeleton of fake `$` rows
/// (Leo, 2026-11-25: "the placeholder's also bad").
public struct TerminalUnreachable: Equatable, Sendable {
    /// Never shown before the shared quiet bound: a blip draws the page's own background only.
    public static let shownAfter: Duration = QuietStatusGate.threshold
    public var title: String
    public var reason: String
    public init(title: String, reason: String) {
        self.title = title
        self.reason = reason
    }

    /// The words for `state` past the quiet bound; `linkStatus` is the link's own status line for
    /// the Mac (a network that blocks the link says so there), preferred over the generic reason.
    public static func make(state: TerminalConnectionState, linkStatus: String?) -> TerminalUnreachable? {
        func named(_ mac: String?) -> String { mac.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "your Mac") }
        let status = linkStatus.flatMap { $0.isEmpty || $0 == "Offline" ? nil : $0 }
        switch state {
        case .attached:
            return nil
        case .offline(let mac):
            return TerminalUnreachable(title: String(localized: "\(named(mac)) is offline"),
                                       reason: status ?? String(localized: "It may be asleep or off the network. This page fills in when it's back."))
        case .failed(let message):
            return TerminalUnreachable(title: String(localized: "Can't reach this terminal"),
                                       reason: status ?? message)
        case .connecting(let mac), .reattaching(let mac):
            return TerminalUnreachable(title: String(localized: "Can't reach \(named(mac))"),
                                       reason: status ?? String(localized: "No answer yet. cmux keeps trying on its own."))
        }
    }
}

/// The no-cache state: nothing (the page's own background) during the quiet bound, then
/// ``TerminalUnreachable`` with Retry. Never fake rows.
struct TerminalUnreachableView: View {
    let state: TerminalUnreachable
    let retry: (@MainActor () async -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Text(state.title)
                .font(.headline)
                .foregroundStyle(Color.white.opacity(0.92))
            Text(state.reason)
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.62))
            if let retry {
                Button(String(localized: "Retry")) { Task { await retry() } }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .padding(.top, 6)
                    .accessibilityIdentifier("terminal.unreachable.retry")
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.unreachable")
    }
}
#endif
