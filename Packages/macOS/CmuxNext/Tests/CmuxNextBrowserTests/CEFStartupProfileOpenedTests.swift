import Foundation
import Testing
@testable import CmuxNextBrowser

/// Chromium opens the default cmux profile at startup (`profile-directory`, #38979), before any
/// pane or the spare window exists. Until one did, `hasOpened(.default)` was false, so Clear
/// Browsing Data took the unopened-profile path and moved that live profile's cache directories
/// aside and deleted them.
@MainActor @Suite struct CEFStartupProfileOpenedTests {
    @Test func theStartupProfileCountsAsOpenedBeforeAnyPaneUsesIt() throws {
        let runtime = try Self.runtime()
        #expect(!runtime.hasOpened(.default))
        runtime.noteStartupProfile(Self.switches(runtime.storage.initialProfileDirectory))
        #expect(runtime.hasOpened(.default))
        #expect(runtime.hosts.isEmpty)
    }

    @Test func noStartupSwitchOpensNoCmuxProfile() throws {
        let runtime = try Self.runtime()
        runtime.noteStartupProfile(Self.switches(nil))
        #expect(!runtime.hasOpened(.default))
    }

    @Test func aDirectoryOtherThanTheDefaultProfilesCountsNone() throws {
        let runtime = try Self.runtime()
        runtime.noteStartupProfile(Self.switches("Default"))
        #expect(!runtime.hasOpened(.default))
    }

    // MARK: Fixtures

    private static func runtime() throws -> CEFRuntime {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-startup-\(UUID().uuidString)", directoryHint: .isDirectory)
        // A shim whose every function answers 0: these tests read only the runtime's own tables.
        let nothing: @convention(c) () -> Int = { 0 }
        let shim = try CEFShimLibrary.resolving { _ in unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self) }
        let runtime = CEFRuntime(shim: shim, storage: CEFProfileStorage(root: root))
        _ = Unmanaged.passRetained(runtime)
        return runtime
    }

    private static func switches(_ directory: String?) -> CEFSwitches {
        CEFSwitches.current(forkAPIVersion: 30, bundleIdentifier: "com.cmuxterm.app.next", environment: [:],
                            initialProfileDirectory: directory)
    }
}
