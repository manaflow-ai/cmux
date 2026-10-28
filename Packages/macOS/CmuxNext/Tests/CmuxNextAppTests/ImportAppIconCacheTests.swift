import CmuxNextCompat
@testable import CmuxNextImportCards
@testable import CmuxNextImportSuggestions
import CmuxNextWakeups
import Foundation
import Testing

/// Settings' import cards never render an app icon on the main thread: reading the card list only takes icons
/// already rendered, and the renders run off the main thread when a scan lands (agent.harness.addFromRegistry
/// opened Settings with 56 ms of Launch Services and PNG work in its turn, macOS 27 STRESS sweep).
@MainActor @Suite(.timeLimit(.minutes(1)))
struct ImportAppIconCacheTests {
    /// Counts renders and the thread each ran on (the render closure runs on the system lane).
    private nonisolated final class Renders: Sendable {
        private let onMain = Mutex<[Bool]>([])
        func note() { onMain.withLock { $0.append(Thread.isMainThread) } }
        var threads: [Bool] { onMain.withLock { $0 } }
    }

    private static let list = ImportCardList(title: "Import", cards: [
        ImportCard(id: "browser.chrome", kind: .browser, app: "com.google.Chrome", title: "Chrome", facts: "", benefit: "",
                   state: .ready, primary: nil, secondary: []),
    ])

    @Test func readingTheCardsRendersNothing() {
        let renders = Renders()
        let icons = ImportAppIconCache(render: { _ in renders.note(); return "data:image/png;base64,AA==" })
        let value = ImportCardJSON.value(Self.list, icons: icons)
        #expect(renders.threads.isEmpty, "the card list rendered an icon in the caller's turn")
        #expect(!"\(value)".contains("data:image"))
    }

    @Test func aLoadRendersOffTheMainThreadOnceAndTheListThenHasIt() {
        let renders = Renders()
        let icons = ImportAppIconCache(render: { _ in renders.note(); return "data:image/png;base64,AA==" })
        let work = BackgroundWork(label: "test.import-icons"), mainWork = MainWorkScheduler(budget: MainFrameBudget())
        icons.load(["com.google.Chrome"], work: work, mainWork: mainWork)
        icons.load(["com.google.Chrome"], work: work, mainWork: mainWork)  // in flight: not rendered twice
        // The render's reply lands as posted main work: main run loop passes until it has.
        Self.spinMainRunLoop { icons.urls["com.google.Chrome"] != nil }
        #expect(renders.threads == [false], "rendered \(renders.threads.count) times; on main: \(renders.threads)")
        #expect("\(ImportCardJSON.value(Self.list, icons: icons))".contains("data:image/png;base64,AA=="))
        icons.load(["com.google.Chrome"], work: work, mainWork: mainWork)  // rendered: never again
        #expect(renders.threads.count == 1)
    }

    /// Runs main run loop passes (where a reply posted from a lane lands) until `done` or 5 s.
    private static func spinMainRunLoop(until done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: 5)
        while !done(), Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }
}
