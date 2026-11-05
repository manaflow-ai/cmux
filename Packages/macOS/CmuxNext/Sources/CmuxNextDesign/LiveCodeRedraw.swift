import CmuxNextLiveCode
public import SwiftUI

extension View {
    /// Redraws this view after each applied live code patch: a new identity, so its body runs
    /// again and reaches the patch's code. Its state starts over, as after a rebuild.
    public func liveCodeRedraw() -> some View { modifier(LiveCodeRedraw()) }
}

@MainActor
struct LiveCodeRedraw: ViewModifier {
    @ObservedObject var live = LiveCode.shared

    func body(content: Content) -> some View {
        // Inside the identity: each generation's new view appears once, after its body ran.
        content
            .onAppear { if live.generation > 0 { live.drawn() } }
            .id(live.generation)
    }
}
