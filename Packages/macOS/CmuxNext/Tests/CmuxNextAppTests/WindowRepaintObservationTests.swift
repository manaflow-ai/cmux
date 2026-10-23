@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// Counts a theme store's repaints (`ThemeStore.repaintAll` calls every responder) and hands
/// each one to the test as a stream element, so the test awaits the repaint instead of waiting.
@MainActor
private final class RepaintCounter: ThemeResponsive {
    let repaints: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private(set) var count = 0

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        repaints = stream
        self.continuation = continuation
    }

    func themeDidChange() {
        count += 1
        continuation.yield()
    }
}

/// Calm mode and the terminal face move no theme color, yet every window draws them (hover
/// fills, the face pages that show code use): the composition root's observation
/// (`AppServices.observeWindowRepaints`) repaints the app's store on each change. Before B3
/// review 2 this was a `DesignSettings.repaintAll` closure AppDelegate installed on the shared
/// settings; without that line nothing repainted and no test noticed. Each test owns its own
/// `DesignSettings` and `ThemeStore`, so no other suite sees its changes.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WindowRepaintObservationTests {
    @Test func aCalmModeChangeRepaintsTheStore() async {
        let design = DesignSettings()
        let store = ThemeStore()
        let counter = RepaintCounter()
        store.addResponder(counter)
        let observation = AppServices.followWindowRepaints(design: design, store: store)
        defer { observation.cancel() }
        var repaints = counter.repaints.makeAsyncIterator()

        design.calmMode = .calm
        _ = await repaints.next()
        #expect(counter.count == 1, "calm mode repainted \(counter.count) times")
    }

    @Test func aTerminalFaceChangeRepaintsTheStore() async {
        let design = DesignSettings()
        let store = ThemeStore()
        let counter = RepaintCounter()
        store.addResponder(counter)
        let observation = AppServices.followWindowRepaints(design: design, store: store)
        defer { observation.cancel() }
        var repaints = counter.repaints.makeAsyncIterator()

        // The Ghostty config's face reaches pages when cmux.json names none.
        design.terminalConfigFontFamily = "Menlo"
        _ = await repaints.next()
        #expect(counter.count == 1)

        // cmux.json's own face wins over the Ghostty config's.
        design.terminalFontFamily = "SF Mono"
        _ = await repaints.next()
        #expect(counter.count == 2)
    }
}
