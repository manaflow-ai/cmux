import Testing
@testable import CmuxMobileTerminalKit

@Test func terminalSurfaceOutputWaitStateCompletesOnlyMatchingGenerationAndID() {
    var waits = TerminalSurfaceOutputWaitState()
    let first = waits.register(generation: 1)
    let second = waits.register(generation: 2)

    let wrongGenerationCompleted = waits.complete(generation: 2, id: first)
    let firstCompleted = waits.complete(generation: 1, id: first)
    let duplicateCompleted = waits.complete(generation: 1, id: first)

    #expect(!wrongGenerationCompleted)
    #expect(firstCompleted)
    #expect(!duplicateCompleted)
    #expect(waits.waitsByGeneration == [2: [second]])
}

@Test func terminalSurfaceOutputWaitStateCancelsAbandonedGenerationOnly() {
    var waits = TerminalSurfaceOutputWaitState()
    let first = waits.register(generation: 10)
    let second = waits.register(generation: 10)
    let third = waits.register(generation: 11)

    #expect(waits.cancel(generation: 10) == [first, second])
    #expect(waits.waitsByGeneration == [11: [third]])
}

@Test func terminalSurfaceOutputWaitStateCancelsAllOnDismantle() {
    var waits = TerminalSurfaceOutputWaitState()
    let first = waits.register(generation: 4)
    let second = waits.register(generation: 5)

    #expect(waits.cancelAll().map(\.id) == [first, second])
    #expect(waits.waitsByGeneration.isEmpty)
}
