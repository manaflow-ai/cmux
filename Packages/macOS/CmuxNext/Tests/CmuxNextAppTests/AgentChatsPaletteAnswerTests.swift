@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextPalette
import Foundation
import Testing

/// Review of #28090, finding 1: the palette's chats page runs its spinner until the query's stream
/// ends (`PalettePageSpec.queryResults`), so the stream ends after acpmux's first answer for the
/// query, an empty one too (the page then shows its empty state, not a spinner forever).
@MainActor @Suite struct AgentChatsPaletteAnswerTests {
    @Test func aQueryStreamEndsAfterAcpmuxAnswersIt() async throws {
        let services = AppServices(environment: AppEnvironment.current(["CMUX_NEXT_NO_ACTIVATE": "1"]))
        let windows = AcpmuxChatWindows()
        var sent: [[String: any Sendable]] = []
        windows.connected { _, params in sent.append(params) }
        let stream = AgentChatsPalettePage.answers("nothing matches", windows: windows, services: services)
        let generation = try #require(sent.last?["gen"] as? UInt64)
        windows.apply(.init(window: AgentChatsPalettePage.window, generation: generation, revision: 1, full: true, keys: [], rows: []))
        var answers: [[PaletteItem]] = []
        for await answer in stream { answers.append(answer) }
        #expect(answers.count == 1, "one answer, then the stream ends")
        #expect(answers.first?.isEmpty == true, "an empty answer shows the empty state")
    }
}
