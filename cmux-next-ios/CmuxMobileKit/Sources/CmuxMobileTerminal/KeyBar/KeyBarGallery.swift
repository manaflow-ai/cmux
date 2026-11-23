#if DEBUG && os(iOS)
import SwiftUI

/// The key row's layouts side by side (`KeyBarLayout`), for screenshots:
/// launch with `-cmux-mobile-recovery-gallery keybar`. Each layout shows the
/// row as it rests on a phone, then its whole row scaled to fit, so the
/// arrows' place is visible without scrolling. The production key row and
/// keys draw it, over the terminal's black, in the dark style the terminal uses.
public struct TerminalKeyBarGallery: View {
    @State private var model = TerminalModel(session: MockTerminalSession(playsIntro: false),
                                             artifactSource: MockArtifactSource())

    /// The whole row's width: every key of the longest layout.
    private static let fullWidth: CGFloat = 1240

    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(KeyBarLayout.allCases, id: \.self) { layout in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(layout.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                            TerminalKeyBar(model: model, layout: layout)
                                .accessibilityIdentifier("keyBarGallery.\(layout.rawValue)")
                            // The whole row, scaled to the screen's width.
                            let scale = proxy.size.width / Self.fullWidth
                            TerminalKeyBar(model: model, layout: layout)
                                .frame(width: Self.fullWidth)
                                .scaleEffect(scale, anchor: .topLeading)
                                .frame(width: proxy.size.width, height: 30 * scale, alignment: .topLeading)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .padding(.vertical, 24)
            }
        }
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}
#endif
