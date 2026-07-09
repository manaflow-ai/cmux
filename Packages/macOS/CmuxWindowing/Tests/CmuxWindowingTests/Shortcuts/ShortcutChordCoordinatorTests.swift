import Testing

@testable import CmuxWindowing

@MainActor
@Suite("ShortcutChordCoordinator")
struct ShortcutChordCoordinatorTests {
    /// A minimal stand-in for the app target's `ShortcutStroke`. The coordinator
    /// is generic over the stroke type, so the test supplies its own.
    private struct Stroke: Hashable, Sendable {
        let key: String
    }

    /// A minimal stand-in for the app target's `StoredShortcut`.
    private struct Shortcut: Hashable {
        let first: Stroke
        let second: Stroke?
        var hasChord: Bool { second != nil }
    }

    private func stroke(_ key: String) -> Stroke { Stroke(key: key) }

    private func chord(_ first: String, _ second: String) -> Shortcut {
        Shortcut(first: stroke(first), second: stroke(second))
    }

    private func single(_ key: String) -> Shortcut {
        Shortcut(first: stroke(key), second: nil)
    }

    private func arm(
        _ coordinator: ShortcutChordCoordinator<Stroke>,
        candidates: [Shortcut],
        windowNumber: Int?,
        matches: @escaping (Stroke) -> Bool
    ) -> Bool {
        coordinator.armIfNeeded(
            candidates: candidates,
            windowNumber: windowNumber,
            isChord: { $0.hasChord },
            firstStroke: { $0.first },
            firstStrokeMatches: matches
        )
    }

    @Test("armIfNeeded arms the first chord whose prefix matches and ignores non-chords")
    func armsMatchingChord() {
        let coordinator = ShortcutChordCoordinator<Stroke>()
        let armed = arm(
            coordinator,
            candidates: [single("a"), chord("b", "c")],
            windowNumber: 42,
            matches: { $0.key == "b" }
        )
        #expect(armed)
        #expect(coordinator.pendingChord == PendingShortcutChord(firstStroke: stroke("b"), windowNumber: 42))
    }

    @Test("armIfNeeded returns false and arms nothing when no chord prefix matches")
    func armsNothingWhenNoMatch() {
        let coordinator = ShortcutChordCoordinator<Stroke>()
        let armed = arm(coordinator, candidates: [chord("b", "c")], windowNumber: 1, matches: { _ in false })
        #expect(!armed)
        #expect(coordinator.pendingChord == nil)
    }

    @Test("armIfNeeded scans a duplicated candidate only once")
    func dedupesCandidates() {
        let coordinator = ShortcutChordCoordinator<Stroke>()
        var matchCalls = 0
        let dup = chord("b", "c")
        _ = arm(coordinator, candidates: [dup, dup], windowNumber: 1, matches: { _ in
            matchCalls += 1
            return false
        })
        #expect(matchCalls == 1)
    }

    @Test("prepareForEvent activates a pending prefix only in the same window")
    func prepareActivatesSameWindow() {
        let coordinator = ShortcutChordCoordinator<Stroke>()
        _ = arm(coordinator, candidates: [chord("b", "c")], windowNumber: 7, matches: { _ in true })
        coordinator.prepareForEvent(windowNumber: 7)
        #expect(coordinator.activePrefixForCurrentEvent == stroke("b"))
        // The pending chord is consumed by the dispatch turn.
        #expect(coordinator.pendingChord == nil)
    }

    @Test("prepareForEvent clears the active prefix for a different window")
    func prepareIgnoresOtherWindow() {
        let coordinator = ShortcutChordCoordinator<Stroke>()
        _ = arm(coordinator, candidates: [chord("b", "c")], windowNumber: 7, matches: { _ in true })
        coordinator.prepareForEvent(windowNumber: 8)
        #expect(coordinator.activePrefixForCurrentEvent == nil)
        #expect(coordinator.pendingChord == nil)
    }

    @Test("prepareForEvent with no pending chord clears the active prefix")
    func prepareWithNoPendingClears() {
        let coordinator = ShortcutChordCoordinator<Stroke>()
        coordinator.activePrefixForCurrentEvent = stroke("z")
        coordinator.prepareForEvent(windowNumber: 1)
        #expect(coordinator.activePrefixForCurrentEvent == nil)
    }

    @Test("clear drops both pending and active state")
    func clearResetsState() {
        let coordinator = ShortcutChordCoordinator<Stroke>()
        _ = arm(coordinator, candidates: [chord("b", "c")], windowNumber: 1, matches: { _ in true })
        coordinator.activePrefixForCurrentEvent = stroke("b")
        coordinator.clear()
        #expect(coordinator.pendingChord == nil)
        #expect(coordinator.activePrefixForCurrentEvent == nil)
    }
}
