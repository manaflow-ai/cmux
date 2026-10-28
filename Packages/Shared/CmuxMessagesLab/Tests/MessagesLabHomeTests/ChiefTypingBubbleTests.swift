import AppKit
@testable import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// The native Home's Chief typing indicator is the Messages typing bubble with its three dots, never a spinner.
/// Leo, 2026-10-28: "Nobody asked for the fucking spinner to be propagated all throughout."
@MainActor
@Suite(.serialized) struct ChiefTypingBubbleTests {
    @Test func nativeTypingShowsThreeDotsAndNoSpinner() async throws {
        let rig = try await HomeChatRig()
        defer { rig.stop() }
        rig.store.handle(.typing(HomeChatRig.conversation, rig.chief, on: true))
        rig.frame()
        let demo = try #require(rig.view.controller.demo)
        let row = try #require(demo.collection.visibleCells.compactMap { $0 as? RowCell }.first {
            if case .typing? = $0.spec?.kind { return true }; return false
        })
        #expect(row.dots.count == 3)
        #expect(row.dots.allSatisfy { $0.superlayer != nil && !$0.isHidden }, "The three dots are drawn")
        #expect(!rotates(row.layer), "Nothing in the typing row rotates")
    }

    private func rotates(_ layer: CALayer) -> Bool {
        let own = (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) }.contains(where: rotates)
        return own || (layer.sublayers ?? []).contains(where: rotates)
    }

    private func rotates(_ animation: CAAnimation) -> Bool {
        if let group = animation as? CAAnimationGroup { return (group.animations ?? []).contains(where: rotates) }
        return ((animation as? CAPropertyAnimation)?.keyPath ?? "").hasPrefix("transform.rotation")
    }
}
