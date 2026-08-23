#if os(iOS)
import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

/// The welcome tour's interactive terminal card.
///
/// Renders the engine's transcript in a fixed dark terminal treatment (a
/// terminal facsimile stays dark in both color schemes) and, while the agent
/// waits on its question, offers the reply chips that resolve it. The whole
/// transcript reads as one accessibility element so VoiceOver hears a session,
/// not a line-by-line list.
struct WelcomeDemoTerminalView: View {
    let engine: WelcomeDemoEngine

    private static let cardBackground = Color(red: 0.07, green: 0.08, blue: 0.10)
    private static let chromeBackground = Color(red: 0.12, green: 0.13, blue: 0.16)

    var body: some View {
        VStack(spacing: 0) {
            windowChrome
            transcript
            if let question = engine.question {
                replyBar(question: question)
            }
        }
        .background(Self.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        )
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("MobileWelcomeDemoTerminal")
    }

    private var windowChrome: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { _ in
                Circle()
                    .fill(.white.opacity(0.18))
                    .frame(width: 9, height: 9)
            }
            Spacer()
            Text(L10n.string("mobile.welcome.demo.windowTitle", defaultValue: "cmux — on your Mac"))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
            // Balances the traffic lights so the title stays centered.
            Color.clear.frame(width: 39, height: 9)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Self.chromeBackground)
        .accessibilityHidden(true)
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(engine.lines) { line in
                text(for: line)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if engine.phase == .playing {
                Text(verbatim: "▍")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .accessibilityHidden(true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .animation(.snappy(duration: 0.25), value: engine.lines)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(transcriptAccessibilityLabel)
    }

    private var transcriptAccessibilityLabel: String {
        let intro = L10n.string(
            "mobile.welcome.demo.accessibilityIntro",
            defaultValue: "Example agent session."
        )
        let body = engine.lines.map(\.text).joined(separator: ". ")
        return "\(intro) \(body)"
    }

    private func replyBar(question: WelcomeDemoQuestion) -> some View {
        HStack(spacing: 8) {
            ForEach(question.replies) { reply in
                Button {
                    MobileHapticFeedback().impact(style: .light)
                    engine.choose(reply)
                } label: {
                    Text(reply.title)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .background(.white.opacity(0.1), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("MobileWelcomeDemoReply-\(reply.id)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func text(for line: WelcomeDemoLine) -> Text {
        let base = Text(verbatim: prefix(for: line.style))
            .foregroundStyle(prefixColor(for: line.style))
            + Text(line.text).foregroundStyle(bodyColor(for: line.style))
        return base.font(.system(.footnote, design: .monospaced))
    }

    private func prefix(for style: WelcomeDemoLine.Style) -> String {
        switch style {
        case .command: "$ "
        case .agent: "◆ "
        case .output: "  "
        case .success: "✓ "
        case .reply: "› "
        }
    }

    private func prefixColor(for style: WelcomeDemoLine.Style) -> Color {
        switch style {
        case .command: .white.opacity(0.5)
        case .agent: Color(red: 0.62, green: 0.55, blue: 1.0)
        case .output: .clear
        case .success: Color(red: 0.35, green: 0.85, blue: 0.55)
        case .reply: Color(red: 0.45, green: 0.8, blue: 1.0)
        }
    }

    private func bodyColor(for style: WelcomeDemoLine.Style) -> Color {
        switch style {
        case .command: .white
        case .agent: .white.opacity(0.92)
        case .output: .white.opacity(0.6)
        case .success: Color(red: 0.35, green: 0.85, blue: 0.55)
        case .reply: Color(red: 0.45, green: 0.8, blue: 1.0)
        }
    }
}
#endif
