import AppKit
@testable import CmuxNextTerminal
import GhosttyNextKit
import Testing

/// `.configChange` carries the decoder's clone of the config Ghostty applied. The dispatcher owns that clone
/// and gives it back exactly once on every path: an app-level change is adopted (the runtime keeps a clone of
/// its own) and still gives it back, so it never leaks; any other one only gives it back. Drives the process's
/// one runtime with its own applied config, so it changes nothing the other suites read.
@MainActor @Suite(.serialized) struct GhosttyActionDispatcherConfigChangeTests {
    @Test("an app-level config change is adopted and its clone given back once")
    func appLevelChangeIsAdoptedAndReleasedOnce() throws {
        _ = NSApplication.shared
        let runtime = GhosttyRuntime.startedForTests()
        let change = try Self.change(cloningConfigOf: runtime)
        let releases = ConfigReleaseCounter()
        let before = runtime.configRevision.value

        let handled = GhosttyActionDispatcher.dispatch(change, bridge: nil, runtime: runtime,
                                                       releaseConfig: { releases.release($0) })

        #expect(handled)
        #expect(runtime.configRevision.value == before + 1, "the runtime did not adopt the change")
        #expect(releases.count == 1, "the decoder's clone was given back \(releases.count) times, not once")
    }

    @Test("a config change with no runtime to adopt it gives its clone back once")
    func changeWithoutRuntimeIsReleasedOnce() throws {
        _ = NSApplication.shared
        let runtime = GhosttyRuntime.startedForTests()
        let change = try Self.change(cloningConfigOf: runtime)
        let releases = ConfigReleaseCounter()
        let before = runtime.configRevision.value

        let handled = GhosttyActionDispatcher.dispatch(change, bridge: nil, runtime: nil,
                                                       releaseConfig: { releases.release($0) })

        #expect(handled)
        #expect(runtime.configRevision.value == before, "nothing adopts a change with no runtime")
        #expect(releases.count == 1, "the decoder's clone was given back \(releases.count) times, not once")
    }

    /// A `.configChange` as the decoder makes it: a new clone of `runtime`'s applied config, which the action owns.
    private static func change(cloningConfigOf runtime: GhosttyRuntime) throws -> GhosttyAction {
        let applied = try #require(runtime.config, "libghostty did not initialize")
        // SAFETY: `applied` is the runtime's live config, read in this turn; the clone is a new handle
        // the action owns until the dispatcher gives it back.
        return .configChange(unsafe UncheckedPointer(raw: ghostty_config_clone(applied)))
    }
}

/// Counts the clones the dispatcher gives back and frees each one, so the suite leaks nothing.
@MainActor private final class ConfigReleaseCounter {
    private(set) var count = 0

    func release(_ handle: UncheckedPointer) {
        count += 1
        // SAFETY: the clone `change(cloningConfigOf:)` made, given back here once per dispatch.
        unsafe ghostty_config_free(handle.raw)
    }
}
