import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// Pins `chrome.cornerFlush` for each test of a suite: `@Suite(.cornerFlush(.off))`.
///
/// The folder tab (`flush-goo`) is the default (design/selected-is-foreground.md). It changes the
/// chrome's geometry: a 4 pt gap and a 12 pt card instead of the gutter, no pane padding, no sidebar
/// edge line, and a selected tab that is a folder instead of a gray pill. A suite that pins the
/// geometry without the folder tab (the gutter, the window-concentric card, the pill's fill) says so
/// with this trait, and the folder tab's own geometry has its own cases (`CornerFlushTests`,
/// `WindowConcentricCornerTests.theFolderTabCardIsConcentricWithTheWindow`). The trait puts back
/// whatever override it found after each test, so it leaks into no other suite.
nonisolated struct CornerFlushPin: SuiteTrait, TestTrait, TestScoping {
    let flush: CornerFlush

    var isRecursive: Bool { true }

    @concurrent func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        guard testCase != nil else { return try await function() }
        let flush = flush
        let before = await MainActor.run { Self.pin(flush) }
        do {
            try await function()
        } catch {
            await MainActor.run { Self.restore(before) }
            throw error
        }
        await MainActor.run { Self.restore(before) }
    }

    @MainActor private static func pin(_ flush: CornerFlush) -> TunableValue? {
        let store = TunableStore.shared
        store.register([CornerFlush.tunable.descriptor])
        if !store.isActive { store.activate(file: nil) }
        let before = store.override(CornerFlush.tunable.key)
        store.set(CornerFlush.tunable.key, flush.tunableValue)
        precondition(CornerFlush.tunable.value == flush, "the chrome.cornerFlush override did not take")
        return before
    }

    @MainActor private static func restore(_ before: TunableValue?) {
        TunableStore.shared.set(CornerFlush.tunable.key, before)
    }
}

extension Trait where Self == CornerFlushPin {
    /// Runs each test of the suite with `chrome.cornerFlush` at `flush` (``CornerFlushPin``).
    static func cornerFlush(_ flush: CornerFlush) -> Self { CornerFlushPin(flush: flush) }
}
