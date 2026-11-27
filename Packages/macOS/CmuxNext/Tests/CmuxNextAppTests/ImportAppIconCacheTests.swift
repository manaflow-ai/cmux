import CmuxNextCompat
@testable import CmuxNextImportCards
@testable import CmuxNextImportSuggestions
import Foundation
import Testing

/// Settings' import cards never render an app icon on the main thread: reading the card list only takes icons
/// already rendered, and the renders run off the main thread when a scan lands (agent.harness.addFromRegistry
/// opened Settings with 56 ms of Launch Services and PNG work in its turn, macOS 27 STRESS sweep).
@MainActor @Suite(.timeLimit(.minutes(1)))
struct ImportAppIconCacheTests {
    /// Counts renders and the thread each ran on (the render closure runs on a detached task).
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

    @Test func aLoadRendersOffTheMainThreadOnceAndTheListThenHasIt() async {
        let renders = Renders()
        let icons = ImportAppIconCache(render: { _ in renders.note(); return "data:image/png;base64,AA==" })
        icons.load(["com.google.Chrome"])
        icons.load(["com.google.Chrome"])  // in flight: not rendered twice
        // ObservationStream yields the current value first, then each change: no window to miss the landing.
        for await landed in ObservationStream({ icons.urls["com.google.Chrome"] != nil }) where landed { break }
        #expect(renders.threads == [false], "rendered \(renders.threads.count) times; on main: \(renders.threads)")
        #expect("\(ImportCardJSON.value(Self.list, icons: icons))".contains("data:image/png;base64,AA=="))
        icons.load(["com.google.Chrome"])  // rendered: never again
        #expect(renders.threads.count == 1)
    }
}
