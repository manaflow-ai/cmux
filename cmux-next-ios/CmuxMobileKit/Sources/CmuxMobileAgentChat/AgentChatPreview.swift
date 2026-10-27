#if os(iOS)
import CmuxMobileDesign
import SwiftUI

/// A static, bottom-aligned rendering of the newest turns: what the chat
/// looks like at rest, for tab grid cards and swipe neighbors. No scroll
/// view, no bindings, no demo commands.
public struct AgentChatPreview: View {
    let store: AgentChatStore
    /// The turns to draw (the last ones); nil reads the store's own. A grid
    /// card passes a copy it updates only while the grid shows and is not
    /// scrolling, so a streaming chat does not re-render its card per token.
    var turns: [AgentTurn]?
    var topInset: CGFloat
    var bottomInset: CGFloat

    public init(store: AgentChatStore, turns: [AgentTurn]? = nil, topInset: CGFloat, bottomInset: CGFloat) {
        self.store = store
        self.turns = turns
        self.topInset = topInset
        self.bottomInset = bottomInset
    }

    public var body: some View {
        // Bottom aligned like the transcript at rest in follow mode: the
        // turns keep their natural height and the overflow clips at the top.
        Color.cmuxMobileBackground
            .overlay(alignment: .bottom) {
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.bottom, bottomInset)
            }
            .overlay(alignment: .top) {
                // The status bar region stays clear, as on the live page.
                Color.clear.frame(height: topInset)
            }
            .clipped()
            .allowsHitTesting(false)
    }

    @ViewBuilder private var content: some View {
        let turns = self.turns ?? store.turns
        if turns.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "sparkle")
                    .font(.system(size: 22))
                    .frame(width: 48, height: 48)
                    .background(Color.cmuxMobileSurfaceRaised, in: .circle)
                Text("What should \(store.summary.agentName) do?").font(.title3.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 240)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(turns.suffix(2)) { turn in
                    TurnView(turn: turn, store: store, isLast: turn.id == turns.last?.id)
                        .padding(.bottom, 24)
                }
            }
        }
    }
}
#endif
