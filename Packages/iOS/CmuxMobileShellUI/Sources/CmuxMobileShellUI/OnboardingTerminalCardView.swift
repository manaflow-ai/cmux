#if os(iOS)
import SwiftUI

/// An animated, decorative terminal vignette used by the welcome pages.
struct OnboardingTerminalCardView: View {
    enum Mode: Equatable {
        case streaming
        case idle
    }

    let mode: Mode

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var animationStart = Date.now

    private let lineCount = 7
    private let idleLineCount = 4
    private let green = Color(red: 0.157, green: 0.784, blue: 0.251)

    var body: some View {
        Group {
            if mode == .streaming {
                card
                    .aspectRatio(4.0 / 5.0, contentMode: .fit)
            } else {
                card
                    .frame(height: 220)
            }
        }
        .frame(maxWidth: 340)
        .accessibilityHidden(true)
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(height: 1)
            terminalBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(red: 0.055, green: 0.065, blue: 0.09))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(red: 1.0, green: 0.373, blue: 0.341).opacity(0.9))
                .frame(width: 8, height: 8)
            Circle().fill(Color(red: 0.996, green: 0.737, blue: 0.180).opacity(0.9))
                .frame(width: 8, height: 8)
            Circle().fill(green.opacity(0.9))
                .frame(width: 8, height: 8)
            Text("claude · api-refactor")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.leading, 4)
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    @ViewBuilder
    private var terminalBody: some View {
        if accessibilityReduceMotion {
            lines(revealed: mode == .streaming ? lineCount : idleLineCount, showsCursor: false)
        } else if mode == .idle {
            lines(revealed: idleLineCount, showsCursor: false)
        } else {
            TimelineView(.periodic(from: animationStart, by: 0.55)) { context in
                let elapsed = max(0, context.date.timeIntervalSince(animationStart))
                let revealed = min(lineCount, Int(elapsed / 0.55) % (lineCount + 4))
                let showsCursor = revealed == lineCount && Int(elapsed / 0.6).isMultiple(of: 2)
                lines(revealed: revealed, showsCursor: showsCursor)
                    .animation(.snappy(duration: 0.25), value: revealed)
            }
        }
    }

    private func lines(revealed: Int, showsCursor: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(0..<revealed, id: \.self) { index in
                terminalLine(index)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if showsCursor {
                Text("▍")
                    .foregroundStyle(green)
                    .transition(.opacity)
            }
        }
        .font(.system(size: 12.5, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private func terminalLine(_ index: Int) -> Text {
        switch index {
        case 0:
            Text("❯").foregroundColor(green)
                + Text(" claude \"add dark mode\"").foregroundColor(.white.opacity(0.9))
        case 1:
            Text("●").foregroundColor(Color(red: 0.298, green: 0.761, blue: 1.0))
                + Text(" Planning 3 steps…").foregroundColor(.white.opacity(0.55))
        case 2:
            Text("✓").foregroundColor(green)
                + Text(" Read src/theme.ts").foregroundColor(.white.opacity(0.75))
        case 3:
            Text("✓").foregroundColor(green)
                + Text(" Edited AppShell.tsx ").foregroundColor(.white.opacity(0.75))
                + Text("+48").foregroundColor(green)
                + Text(" ").foregroundColor(.white.opacity(0.75))
                + Text("−12").foregroundColor(Color(red: 1.0, green: 0.420, blue: 0.420))
        case 4:
            Text("⚙ Running tests…").foregroundColor(.white.opacity(0.55))
        case 5:
            Text("✓ 24 passed in 3.1s").foregroundColor(green)
        default:
            Text("●").foregroundColor(Color(red: 1.0, green: 0.702, blue: 0.251))
                + Text(" Waiting for your review").foregroundColor(.white.opacity(0.9))
        }
    }
}
#endif
