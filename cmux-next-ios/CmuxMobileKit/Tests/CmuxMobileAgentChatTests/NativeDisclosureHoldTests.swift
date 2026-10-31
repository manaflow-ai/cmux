#if os(iOS)
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// A native tool row's disclosure tap changed the open state without the transcript's
/// hold (the SwiftUI rows' `toggleDisclosure` has one), so a reader on the newest row was
/// carried to the new bottom past the output they opened. The tap now holds the tapped
/// line, as the SwiftUI rows do; the transcript's cap lets go.
@MainActor
@Suite struct NativeDisclosureHoldTests {
    @MainActor final class Holds {
        var begun = 0
        var ended = 0
    }

    @Test func aNativeToolTapHoldsTheTappedLine() {
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        let surface = AgentChatSurface()
        let holds = Holds()
        surface.foldHold = TranscriptFoldHold(begin: { holds.begun += 1 }, end: { holds.ended += 1 })
        let call = ACPToolCall(id: "c1", title: "Run tests", kind: .execute, status: .completed)
        var actions = ChatNativeActions()
        ChatNativeRowActions.configure(&actions, row: ChatRow(id: "tool-c1", turnID: "t", kind: .tool(call), gap: 0),
                                       context: ChatRowContext(store: store, surface: surface))
        actions.hit(.toggle("tool-c1"))
        #expect(holds.begun == 1, "the tap holds the line before the row opens")
        #expect(surface.disclosures.isOpen("tool-c1") == true)
        #expect(holds.ended == 0, "held while the row's layout plays")
    }
}
#endif
