@testable import CmuxNextBrowser
import CmuxNextCompat
import Foundation
import Testing

/// p08-startup-044: Chromium's start as launch marks (`CEFLaunchMarks`), each sent once per process to
/// the receiver the App installs (`CEFEngine.installLaunchMarks`), with the first page paint followed by
/// the trigger of the start. Against runtimes that never load Chromium.
@MainActor @Suite(.serialized) struct CEFLaunchMarksTests {
    @Test func eachMarkGoesOutOnce() {
        let log = CEFLaunchMarkLog()
        var marks = CEFLaunchMarks()
        marks.receiver = log.receive
        for mark in CEFLaunchMarks.Mark.allCases where mark != .libraryLoaded {
            #expect(marks.send(mark))
            #expect(!marks.send(mark), "\(mark.rawValue) went out twice")
        }
        #expect(log.names == CEFLaunchMarks.Mark.allCases.filter { $0 != .libraryLoaded }.map(\.rawValue))
    }

    @Test func theFirstPagePaintNamesItsTrigger() {
        let log = CEFLaunchMarkLog()
        var marks = CEFLaunchMarks()
        marks.receiver = log.receive
        marks.firstPagePainted(trigger: "restoredTab")
        marks.firstPagePainted(trigger: "tab")
        #expect(log.names == ["cef.first_page_paint", "cef.first_page_paint.trigger.restoredTab"])
    }

    /// The load task's send is taken once: a second take sends nothing, from any thread.
    @Test func theLibraryLoadSendIsTakenOnce() async {
        let log = CEFLaunchMarkLog()
        var marks = CEFLaunchMarks()
        marks.receiver = log.receive
        let first = marks.libraryLoadedSend()
        let second = marks.libraryLoadedSend()
        await Task.detached { first(); second() }.value
        #expect(log.names == ["cef.library_loaded"])
        #expect(!marks.send(.libraryLoaded))
    }

    /// A preload starts the one load: `cef.preload_started` once, and no `cef.library_loaded` for a load
    /// that failed. The start that follows awaits the same load and marks nothing more.
    @Test func aFailedPreloadMarksItsStartOnly() async {
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: Self.scratch()))
        let log = CEFLaunchMarkLog()
        runtime.launchMarks.receiver = log.receive
        runtime.loadInProcess = { _ in .failure(.notEmbedded) }

        runtime.preload(layout: nil)
        runtime.preload(layout: nil)
        await #expect(throws: BrowserEngineError.self) {
            try await runtime.start(layout: nil, environment: [:], trigger: "test")
        }

        #expect(log.names == ["cef.preload_started"])
    }

    /// The first Chromium page's paint marks the trigger the runtime started with; later paints mark nothing.
    @Test func laterPagePaintsMarkNothing() {
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: Self.scratch()))
        let log = CEFLaunchMarkLog()
        runtime.launchMarks.receiver = log.receive
        runtime.firstPagePainted()
        runtime.firstPagePainted()
        #expect(log.names == ["cef.first_page_paint", "cef.first_page_paint.trigger.tab"])
    }

    private static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cef-launch-marks-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}

/// The mark names a receiver got, in order, from any thread.
nonisolated final class CEFLaunchMarkLog: Sendable {
    private let state = Mutex<[String]>([])

    var names: [String] { state.withLock { $0 } }

    var receive: @Sendable (String) -> Void { { [self] name in state.withLock { $0.append(name) } } }
}
