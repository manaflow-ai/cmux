import Darwin
import Dispatch
import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Browser discovery executor")
struct BrowserInstalledBrowserDetectorAsyncTests {
    @MainActor
    @Test("real profile discovery leaves the UI actor and preserves injected paths")
    func offMainDetectionPreservesResults() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-browser-import-async-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = home.appendingPathComponent(
            "Library/Application Support/Google/Chrome/Default", isDirectory: true
        )
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let marker = Data(UUID().uuidString.utf8)
        try marker.write(to: profile.appendingPathComponent("History"))

        let service = BrowserInstalledBrowserDetectionService {
            #expect(pthread_main_np() == 0)
            return BrowserInstalledBrowserDetector(
                homeDirectoryURL: home,
                bundleLookup: { _ in
                    #expect(pthread_main_np() == 0)
                    return nil
                },
                applicationSearchDirectories: []
            ).detectInstalledBrowsers()
        }
        let candidates = await service.detectInstalledBrowsers()
        let chrome = try #require(candidates.first { $0.id == "google-chrome" })
        let foundProfile = try #require(chrome.profiles.first)
        #expect(chrome.homeDirectoryURL == home)
        #expect(foundProfile.rootURL.lastPathComponent == "Default")
        #expect(try Data(contentsOf: foundProfile.rootURL.appendingPathComponent("History")) == marker)
    }

    @MainActor
    @Test("a blocked system scan leaves the main actor runnable")
    func slowScanDoesNotBlockMainActor() async {
        let (started, continuation) = AsyncStream<Void>.makeStream()
        // This semaphore deliberately simulates a blocking system call on the
        // I/O lane. It is never waited on by the test's main actor.
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); continuation.finish() }
        let service = BrowserInstalledBrowserDetectionService {
            continuation.yield(())
            release.wait()
            return []
        }
        let discovery = Task { await service.detectInstalledBrowsers() }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        #expect(pthread_main_np() != 0)
        release.signal()
        #expect(await discovery.value.isEmpty)
    }
}
