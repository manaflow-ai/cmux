#if os(iOS)
import CmuxMobileDesign
import SwiftUI

/// A terminal-shaped page (six lines of output, the composer) with a connection chip in one of
/// the three placements the gallery compares. The gallery draws it and
/// `TerminalChipCoverageTests` measures it, so the shots and the covered-area numbers are the
/// same layout.
struct TerminalChipPage: View {
    enum Variant: String, CaseIterable {
        /// Top center, spinner or symbol plus the words.
        case a
        /// Above the composer, leading.
        case b
        /// The symbol alone, top trailing.
        case c
    }

    static let states: [ConnectionChip.Content] = [
        .init(.connecting, sentence: "Connecting to Mac Studio…"),
        .init(.reconnecting, sentence: "Reconnecting to Mac Studio…"),
        .init(.macOffline, sentence: "Mac Studio is offline"),
        .init(.cantReach, sentence: "Can't reach this terminal"),
    ]

    static let lineCount = 6

    let variant: Variant
    let state: ConnectionChip.Content
    /// The chip's frame and each output line's frame, in the page's space (for the test).
    var onChipFrame: (CGRect) -> Void = { _ in }
    var onLineFrame: (Int, CGRect) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // visible-only: a fixed page of six lines.
            ForEach(0 ..< Self.lineCount, id: \.self) { i in
                Text(verbatim: i == Self.lineCount - 1 ? "$ " : "line \(i + 1) of the build output")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { onLineFrame(i, $0) }
            }
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white.opacity(0.12))
                .frame(height: 44)
        }
        .padding(12)
        .frame(height: 210)
        .background(Color.black)
        .overlay(alignment: alignment) {
            chip
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { onChipFrame($0) }
                .padding(alignment == .top || alignment == .topTrailing ? .top : .bottom, alignment == .bottomLeading ? 64 : 8)
                .padding(.horizontal, 12)
        }
        .coordinateSpace(.named(Self.space))
        .environment(\.colorScheme, .dark)
    }

    static let space = "terminalChipPage"

    private var alignment: Alignment {
        switch variant {
        case .a: .top
        case .b: .bottomLeading
        case .c: .topTrailing
        }
    }

    @ViewBuilder private var chip: some View {
        switch variant {
        case .a: ConnectionChip(state, retry: state.symbol == nil ? nil : {})
        case .b: ConnectionChip(state)
        case .c: ConnectionChip.SymbolOnly(state)
        }
    }
}
#endif
