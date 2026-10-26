@testable import CmuxNextBrowser
import Foundation
import Testing

/// p08-startup-046: when the Chromium Host ends, every page it showed shows the crash state of its
/// end, every reply still awaited fails, and the runtime goes on (only the host's process ended).
/// Against a spy shim whose every export does nothing, with a supervisor that reports host ends.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CEFRuntimeHostExitTests {
    private static let killed = BrowserProcessExit(reason: .killed, code: Int(SIGKILL), engine: .cef)

    @Test func aReportedHostEndShowsTheCrashStateOnEveryPage() throws {
        let supervisor = ReportingHost()
        let (runtime, root) = try Self.runtime(supervisor: supervisor)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Self.tab(runtime, browser: 1)
        let second = Self.tab(runtime, browser: 2)
        var answers: [CEFContentSetting?] = []
        runtime.contentSetting(1, url: nil, kind: .camera) { answers.append($0) }

        let report = try #require(supervisor.onHostEnded, "the runtime does not follow the supervisor's host ends")
        report(Self.killed)

        #expect(first.state.processExit == Self.killed)
        #expect(second.state.processExit == Self.killed)
        #expect(answers == [nil], "a reply awaited from the dead host never ended")
        #expect(runtime.crashLog.records.contains { $0.processType == "chromium-host" && $0.reason == .killed })
        #expect(runtime.state == .ready)
    }

    @Test func inProcessAHostEndDoesNothing() throws {
        let (runtime, root) = try Self.runtime(supervisor: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = Self.tab(runtime, browser: 1)

        runtime.hostEnded(Self.killed)

        #expect(tab.state.processExit == nil)
        #expect(runtime.crashLog.records.isEmpty)
    }

    @Test func aSupervisorThatDoesNotReportEndsIsOnlyAttached() throws {
        let (runtime, root) = try Self.runtime(supervisor: nil)
        defer { try? FileManager.default.removeItem(at: root) }

        runtime.adoptHost(SilentHost())

        #expect(runtime.hostStart != nil)
    }

    // MARK: Fixtures

    /// A ready runtime over the spy shim that outlives the test (a pane's scheduled work reads it
    /// through an unowned reference); in host mode through `supervisor` when one is given.
    private static func runtime(supervisor: ReportingHost?) throws -> (CEFRuntime, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-host-exit-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(HostExitSpy.symbol), storage: CEFProfileStorage(root: root))
        if let supervisor {
            runtime.adoptHost(supervisor)
            let hostStart = try #require(runtime.hostStart)
            runtime.hostReplies = try CEFHostReplyRoute(symbol: HostExitSpy.symbol, replies: hostStart.replies)
        }
        _ = Unmanaged.passRetained(runtime)
        return (runtime, root)
    }

    /// A tab in a pane of its own whose browser is `browser`.
    private static func tab(_ runtime: CEFRuntime, browser: Int32) -> CEFTab {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        runtime.register(tab, browser: browser)
        return tab
    }
}

/// Never attaches; reports host ends through ``onHostEnded``, which the runtime sets.
@MainActor private final class ReportingHost: ChromiumHostExitReporting {
    var onHostEnded: (@MainActor (BrowserProcessExit) -> Void)?

    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        throw .cannotStart("not started in this test")
    }
}

/// Never attaches and reports nothing.
@MainActor private final class SilentHost: ChromiumHostSupervising {
    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        throw .cannotStart("not started in this test")
    }
}

/// The spy shim: every export does nothing and returns 0; `cmux_remote_shim_last_reply_token` names
/// one reply, so an async call in host mode awaits it.
private nonisolated enum HostExitSpy {
    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let lastReplyToken: CEFHostReplyRoute.LastReplyTokenFn = { 41 }
        let nothing: @convention(c) () -> Int = { 0 }
        return name == "cmux_remote_shim_last_reply_token"
            ? unsafeBitCast(lastReplyToken, to: UnsafeMutableRawPointer.self)
            : unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
    }
}
