import CryptoKit
import Foundation
@testable import CmuxNextBrowser
import Testing

/// React Grab (`toggleReactGrab`): the first toggle on a page loads the pinned react-grab library
/// into the page world (Chromium and WebKit alike) and turns it on, so a click on an element copies
/// its React component source. Later toggles turn the loaded library off and on without loading it
/// again. The library is fetched once per app run and refused when its SHA-256 differs from the pin.
@MainActor @Suite struct ReactGrabTests {
    /// Hands out a fixed library and counts the calls.
    actor FixedSource: ReactGrabScriptSource {
        var calls = 0
        let library: String
        init(_ library: String) { self.library = library }
        func script() async throws -> String {
            calls += 1
            return library
        }
    }

    static func tab(_ engine: BrowserEngineKind, libraryLoaded: Bool) -> MockBrowserTab {
        let tab = MockBrowserEngine(kind: engine).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/"), origin: .user))
        // The toggle probe answers whether the page already has the library.
        tab.evaluationResult = .bool(libraryLoaded)
        return tab
    }

    static func evaluated(_ tab: MockBrowserTab) -> [String] {
        tab.commands.compactMap { if case .evaluate(let script) = $0 { script } else { nil } }
    }

    @Test(arguments: [BrowserEngineKind.cef, .webkit])
    func theFirstToggleLoadsTheLibraryIntoThePageAndTurnsItOn(_ engine: BrowserEngineKind) async throws {
        let source = FixedSource("window.__LIB__ = 1;")
        let tab = Self.tab(engine, libraryLoaded: false)
        let outcome = try await ReactGrab(scripts: source).toggle(tab)
        #expect(outcome == .loaded)
        #expect(await source.calls == 1)
        let scripts = Self.evaluated(tab)
        #expect(scripts.count == 2, "a probe, then the library with its activation")
        let injected = try #require(scripts.last)
        #expect(injected.hasPrefix("window.__LIB__ = 1;"))
        #expect(injected.contains(".activate()"), "the loaded library starts on")
    }

    @Test(arguments: [BrowserEngineKind.cef, .webkit])
    func aPageWithTheLibraryTogglesItWithoutLoadingAgain(_ engine: BrowserEngineKind) async throws {
        let source = FixedSource("window.__LIB__ = 1;")
        let tab = Self.tab(engine, libraryLoaded: true)
        let outcome = try await ReactGrab(scripts: source).toggle(tab)
        #expect(outcome == .toggled)
        #expect(await source.calls == 0, "no fetch when the page has the library")
        #expect(Self.evaluated(tab).count == 1)
        #expect(Self.evaluated(tab).first?.contains(".toggle()") == true)
    }

    @Test func theLoaderFetchesThePinnedVersionOnceAndChecksItsHash() async throws {
        let body = Data("window.__REACT_GRAB__ = {};".utf8)
        let hex = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let fetched = FetchLog()
        let loader = ReactGrabScriptLoader(version: "9.9.9", sha256: hex) { url in
            await fetched.record(url)
            return body
        }
        #expect(try await loader.script() == "window.__REACT_GRAB__ = {};")
        #expect(try await loader.script() == "window.__REACT_GRAB__ = {};")
        #expect(await fetched.urls == [URL(string: "https://unpkg.com/react-grab@9.9.9/dist/index.global.js")!])
    }

    @Test func theLoaderRefusesALibraryWhoseHashDiffersFromThePin() async {
        let loader = ReactGrabScriptLoader(version: "9.9.9", sha256: String(repeating: "0", count: 64)) { _ in
            Data("tampered".utf8)
        }
        await #expect(throws: ReactGrabError.integrityMismatch) { try await loader.script() }
    }

    @Test func theDefaultPinIsTheShippedReactGrabRelease() {
        let loader = ReactGrabScriptLoader { _ in Data() }
        #expect(loader.url == URL(string: "https://unpkg.com/react-grab@0.1.29/dist/index.global.js")!)
    }

    actor FetchLog {
        var urls: [URL] = []
        func record(_ url: URL) { urls.append(url) }
    }
}
