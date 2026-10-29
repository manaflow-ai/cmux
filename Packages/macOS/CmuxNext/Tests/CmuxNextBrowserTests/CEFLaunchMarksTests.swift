@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextInput
import Foundation
import Testing

/// Chromium's start as launch marks (`CEFLaunchMarks`), each sent once per process to
/// the receiver the App gives the engine (`CEFLaunchMarkHooks`), with the startup page's first paint
/// followed by the trigger of the start. Against runtimes that never run Chromium.
@MainActor @Suite(.serialized) struct CEFLaunchMarksTests {
    @Test func eachMarkGoesOutOnce() {
        let log = CEFLaunchMarkLog()
        var marks = CEFLaunchMarks()
        marks.receiver = log.receive
        for mark in CEFLaunchMarks.Mark.allCases where mark != .libraryLoaded {
            let sent = marks.send(mark)
            #expect(sent)
            let sentAgain = marks.send(mark)
            #expect(!sentAgain, "\(mark.rawValue) went out twice")
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
        let sentAfterTake = marks.send(.libraryLoaded)
        #expect(!sentAfterTake)
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

    /// A load that maps the framework marks, in order: `cef.preload_started` as the preload makes it,
    /// `cef.library_loaded` from the load task, then `cef.initialize_started` when the start runs the
    /// initialize. The spy shim refuses the application step, so this initialize fails and sends no
    /// `cef.initialize_ended` (the host-mode start in CEFRuntimeBackendTests marks the pair); a second
    /// start marks nothing.
    @Test func aLoadedPreloadMarksInOrder() async throws {
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: Self.scratch()))
        let log = CEFLaunchMarkLog()
        runtime.launchMarks.receiver = log.receive
        let library = try LoadedLibrarySpy.library()
        runtime.loadInProcess = { _ in .success(library) }

        runtime.preload(layout: library.layout)
        await #expect(throws: BrowserEngineError.self) {
            try await runtime.start(layout: library.layout, environment: [:], trigger: "test")
        }
        #expect(log.names == ["cef.preload_started", "cef.library_loaded", "cef.initialize_started"])

        await #expect(throws: BrowserEngineError.self) {
            try await runtime.start(layout: library.layout, environment: [:], trigger: "test")
        }
        #expect(log.names == ["cef.preload_started", "cef.library_loaded", "cef.initialize_started"])
    }

    /// The first shown Chromium page's paint marks the trigger the runtime started with; later paints mark nothing.
    @Test func laterPagePaintsMarkNothing() {
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: Self.scratch()))
        let log = CEFLaunchMarkLog()
        runtime.launchMarks.receiver = log.receive
        runtime.firstPagePainted(shown: true)
        runtime.firstPagePainted(shown: true)
        #expect(log.names == ["cef.first_page_paint", "cef.first_page_paint.trigger.tab"])
    }

    /// A hidden tab's paint is not the startup's: it sends nothing, and the shown page's paint after it
    /// still marks the first page paint.
    @Test func aHiddenTabsPaintSendsNothing() {
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: Self.scratch()))
        let log = CEFLaunchMarkLog()
        runtime.launchMarks.receiver = log.receive
        runtime.launchIsStarting = { true }

        runtime.firstPagePainted(shown: false)
        #expect(log.names.isEmpty, "a hidden tab's paint was marked")

        runtime.firstPagePainted(shown: true)
        #expect(log.names == ["cef.first_page_paint", "cef.first_page_paint.trigger.tab"])
    }

    /// A shown page's first paint after the launch completed is abandoned, as Chrome's
    /// FirstWebContentsProfiler abandons: nothing goes out then, nor for any later paint.
    @Test func aPaintAfterTheLaunchIsAbandoned() {
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: Self.scratch()))
        let log = CEFLaunchMarkLog()
        runtime.launchMarks.receiver = log.receive
        var starting = false
        runtime.launchIsStarting = { starting }

        runtime.firstPagePainted(shown: true)
        starting = true
        runtime.firstPagePainted(shown: true)

        #expect(log.names.isEmpty)
    }

    /// The engine gives the process-wide runtime the App's hooks as it is built (no static install).
    @Test func theEngineGivesTheRuntimeItsHooks() {
        let runtime = CEFRuntime.shared
        let (receiver, isStarting) = (runtime.launchMarks.receiver, runtime.launchIsStarting)
        defer { (runtime.launchMarks.receiver, runtime.launchIsStarting) = (receiver, isStarting) }
        let log = CEFLaunchMarkLog()

        _ = CEFEngine(source: CEFRuntimeSource(layout: nil), stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(),
                      input: InputEventTap(), launchMarks: CEFLaunchMarkHooks(receive: log.receive, isStarting: { false }))

        #expect(runtime.launchMarks.receiver != nil)
        #expect(runtime.launchIsStarting?() == false)
    }

    private static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cef-launch-marks-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}

/// A mapped library over a shim whose every function does nothing and returns 0: its application
/// step refuses, so a start's initialize fails before Chromium code runs.
private nonisolated enum LoadedLibrarySpy {
    static func library() throws -> CEFLoadedLibrary {
        let nothing: @convention(c) () -> Int = { 0 }
        let shim = try CEFShimLibrary.resolving { _ in unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self) }
        let missing = FileManager.default.temporaryDirectory.appending(path: "cef-launch-marks-missing-\(UUID().uuidString)")
        let layout = CEFRuntimeLayout(frameworksDirectory: missing, mainBundle: missing, helperApp: missing)
        return CEFLoadedLibrary(shim: shim, shimABI: "", layout: layout,
                                locale: CEFLocale(locale: CEFLocale.fallback, acceptLanguages: CEFLocale.fallback), loadDuration: .zero)
    }
}

/// The mark names a receiver got, in order, from any thread.
nonisolated final class CEFLaunchMarkLog: Sendable {
    private let state = Mutex<[String]>([])

    var names: [String] { state.withLock { $0 } }

    var receive: @Sendable (String) -> Void { { [self] name in state.withLock { $0.append(name) } } }
}
