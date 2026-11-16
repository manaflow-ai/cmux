@testable import CmuxNextBrowser
import Darwin
import Foundation
import os
import Testing

/// The Chromium framework is mapped only on a background thread (`dlopen` holds dyld's loader lock; a main-thread
/// `dlopen` or `dladdr` meanwhile waits on it), once, and nothing initializes Chromium until a page asks. Each test
/// injects a recording loader (``CEFRuntime/LibraryLoader``) into its own runtime; no real framework loads.
@MainActor struct CEFLibraryMapOffMainTests {
    /// Each loader call: whether it ran on the main thread.
    nonisolated final class LoaderLog: Sendable {
        private let calls = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        var onMain: [Bool] { calls.withLock { $0 } }

        func loader() -> CEFRuntime.LibraryLoader {
            { [self] _ in
                calls.withLock { $0.append(pthread_main_np() != 0) }
                return .failure(.notEmbedded)
            }
        }
    }

    static let layout = CEFRuntimeLayout(frameworksDirectory: URL(filePath: "/nonexistent/Frameworks", directoryHint: .isDirectory),
                                         mainBundle: URL(filePath: "/nonexistent/App.app", directoryHint: .isDirectory),
                                         helperApp: URL(filePath: "/nonexistent/Frameworks/Helper.app", directoryHint: .isDirectory))

    @Test func thePreloadMapsOnceOffTheMainThreadAndInitializesNothing() async {
        let log = LoaderLog()
        let runtime = CEFRuntime(libraryLoader: log.loader())
        runtime.preload(layout: Self.layout)
        #expect(log.onMain.allSatisfy { !$0 }, "preload itself calls no loader on the main thread")
        _ = await runtime.loadTask?.value
        #expect(log.onMain == [false], "one map, off the main thread")
        #expect(runtime.state == .loading, "no CefInitialize before a page asks")

        // A page asks: the main thread takes the preload's result and maps nothing again.
        await #expect(throws: BrowserEngineError.self) { try await runtime.start(layout: Self.layout) }
        #expect(log.onMain == [false])
    }

    @Test func aPageThatAsksFirstMapsOffTheMainThread() async {
        let log = LoaderLog()
        let runtime = CEFRuntime(libraryLoader: log.loader())
        await #expect(throws: BrowserEngineError.self) { try await runtime.start(layout: Self.layout) }
        #expect(log.onMain == [false])
    }

    /// launch-restored-chat begins the load ahead of the restored chat page (`CEFEngine.beginEarlyLoad`): the
    /// page's start takes that load and loads nothing again.
    @Test func anEarlyLoadIsAdoptedByStartWithNoSecondLoad() async {
        let log = LoaderLog()
        let runtime = CEFRuntime(libraryLoader: log.loader())
        let earlyLoad = CEFEarlyLoad(loader: log.loader())
        // Begun off the main actor, as the restored chat's launch images begin it.
        let layout = Self.layout
        let early = await Task.detached { earlyLoad.begin(layout) }.value
        #expect(earlyLoad.begin(Self.layout) == early, "a second begin returns the same task")
        _ = await early.value
        #expect(log.onMain == [false])
        runtime.adopt(earlyLoad: earlyLoad)
        await #expect(throws: BrowserEngineError.self) { try await runtime.start(layout: Self.layout) }
        #expect(log.onMain == [false], "start took the early load")
    }

    @Test func anEarlyLoadOfAnotherLayoutIsNotAdopted() async {
        let log = LoaderLog()
        let runtime = CEFRuntime(libraryLoader: log.loader())
        let earlyLoad = CEFEarlyLoad(loader: log.loader())
        runtime.adopt(earlyLoad: earlyLoad)
        var other = Self.layout
        other.frameworksDirectory = URL(filePath: "/elsewhere/Frameworks", directoryHint: .isDirectory)
        _ = await earlyLoad.begin(other).value
        await #expect(throws: BrowserEngineError.self) { try await runtime.start(layout: Self.layout) }
        #expect(log.onMain == [false, false], "start loaded its own layout")
    }
}
