#if DEBUG && os(iOS)
import SwiftUI

/// The key row's styles (`KeyBarStyle`) and layouts (`KeyBarLayout`) side by
/// side, for screenshots: launch with `-cmux-mobile-recovery-gallery keybar`.
/// Each shows the row as it rests on a phone over the keyboard, then its
/// whole row scaled to fit, so every key's place is visible without
/// scrolling. The production key row and keys draw it, over the terminal's
/// black, in the dark style the terminal uses.
public struct TerminalKeyBarGallery: View {
    @State private var model = TerminalModel(session: MockTerminalSession(playsIntro: false),
                                             artifactSource: MockArtifactSource())

    /// The whole row's width: every key of the longest layout at 44 pt.
    private static let fullWidth: CGFloat = 1900

    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(KeyBarStyle.allCases, id: \.self) { style in
                        row(title: style.title, layout: .current, width: proxy.size.width)
                            .environment(\.keyBarStyle, style)
                            .accessibilityIdentifier("keyBarGallery.style.\(style.rawValue)")
                    }
                    ForEach(KeyBarLayout.allCases, id: \.self) { layout in
                        row(title: layout.title, layout: layout, width: proxy.size.width)
                            .accessibilityIdentifier("keyBarGallery.\(layout.rawValue)")
                    }
                }
                .padding(.vertical, 24)
            }
        }
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }

    private func row(title: String, layout: KeyBarLayout, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
            TerminalKeyBar(model: model, layout: layout)
            // The whole row, scaled to the screen's width.
            let scale = width / Self.fullWidth
            TerminalKeyBar(model: model, layout: layout)
                .frame(width: Self.fullWidth)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: width, height: (TerminalDockMetrics.keyRowHeight + 2) * scale, alignment: .topLeading)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
    }
}
#endif
