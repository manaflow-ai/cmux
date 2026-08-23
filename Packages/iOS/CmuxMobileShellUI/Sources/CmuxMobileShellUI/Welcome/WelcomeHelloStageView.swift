#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The tour's opening stage: an interactive demo instead of a slide.
///
/// A scripted agent session plays in a terminal card and pauses on a question
/// the person answers by tapping a reply, performing the product's core loop
/// before any setup. The engine is owned here and cancelled when the stage
/// leaves the screen.
struct WelcomeHelloStageView: View {
    /// Collapses playback delays for Reduce Motion and deterministic UI tests.
    let revealsInstantly: Bool

    @State private var engine: WelcomeDemoEngine?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text(L10n.string(
                    "mobile.welcome.hello.title",
                    defaultValue: "Agents work on your Mac.\nYou keep them moving."
                ))
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
                Text(L10n.string(
                    "mobile.welcome.hello.subtitle",
                    defaultValue: "cmux runs AI coding agents in terminals on your Mac. When one needs you, answer from your phone. Try it below."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            if let engine {
                WelcomeDemoTerminalView(engine: engine)
            }
        }
        .accessibilityIdentifier("MobileWelcomeStage-hello")
        .onAppear {
            // A finished or question-paused transcript survives leaving and
            // returning; playback interrupted mid-reveal (cancelled on
            // disappear) restarts from the top.
            if let engine, engine.phase != .playing {
                return
            }
            let engine = WelcomeDemoEngine(
                revealsInstantly: revealsInstantly || reduceMotion
            )
            self.engine = engine
            engine.start()
        }
        .onDisappear {
            engine?.cancel()
        }
    }
}
#endif
