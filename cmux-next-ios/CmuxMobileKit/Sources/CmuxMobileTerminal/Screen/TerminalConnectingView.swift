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

    public init(topInset: CGFloat = 0, lastFrame: UIImage? = nil, showsPlaceholder: Bool = true,
                screenText: String? = nil) {
        self.topInset = topInset
        self.lastFrame = lastFrame
        self.showsPlaceholder = showsPlaceholder
        self.screenText = screenText
    }

    /// What the view draws: the cached frame wins; the skeleton only with no
    /// cache at all.
    enum Content: Equatable {
        case lastFrame
        case screenText
        case skeleton
        case nothing
    }

    static func content(hasLastFrame: Bool, showsPlaceholder: Bool, hasScreenText: Bool = false) -> Content {
        if hasLastFrame { return .lastFrame }
        // Only where the skeleton would be: a warm surface keeps its own live rows.
        if hasScreenText, showsPlaceholder { return .screenText }
        return showsPlaceholder ? .skeleton : .nothing
    }

    /// Line widths of the skeleton, as fractions of the width: a prompt, some
    /// output, a prompt.
    private static let lines: [CGFloat] = [0.42, 0.78, 0.64, 0.86, 0.52, 0.7, 0.3]

    private var skeleton: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(Self.lines.enumerated()), id: \.offset) { _, fraction in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: (proxy.size.width - 24) * fraction, height: 12)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, topInset + 16)
            .cmuxMobileShimmer()
        }
        .accessibilityHidden(true)
    }

    public var body: some View {
        ZStack(alignment: .top) {
            switch Self.content(hasLastFrame: lastFrame != nil, showsPlaceholder: showsPlaceholder,
                                hasScreenText: screenText?.isEmpty == false) {
            case .lastFrame:
                if let lastFrame {
                    GeometryReader { proxy in
                        Image(uiImage: lastFrame)
                            .resizable()
                            .interpolation(.medium)
                            .frame(width: proxy.size.width,
                                   height: proxy.size.width * lastFrame.size.height / max(1, lastFrame.size.width))
                            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                            .clipped()
                    }
                    .accessibilityHidden(true)
                }
            case .screenText:
                GeometryReader { proxy in
                    // Not dimmed: a grayed-out page reads as one that takes no input (Leo,
                    // 2026-11-24: "the entire thing is somehow grayed out").
                    TerminalCardScreenText(text: screenText ?? "", topInset: topInset, width: proxy.size.width)
                }
                .accessibilityHidden(true)
            case .skeleton:
                skeleton
            case .nothing:
                EmptyView()
            }
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier("terminal.connecting")
        .environment(\.colorScheme, .dark)
    }
}
#endif
