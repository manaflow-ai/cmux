import AppKit
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDaemon
import Foundation
import os
import Testing

/// No O(all) work per event (perf-lead.md cause 6, row 8). The control snapshot publisher
/// rebuilt the whole topology (every workspace of every machine, each pane's app facts, the
/// closed tabs and the trail for Search Tabs) on the frame after every key or activation
/// notice: each Cmd-Tab (resign and become active, resign and become key) and each panel that
/// takes the keys (the palette) paid O(workspaces + panes) before its frame. Those notices move
/// only which window is key and where the focus is: the window facts, O(windows).
///
/// Full rebuilds are counted by the publisher's own timing list (`debug.timings`
/// `control_publishes`, one entry per full publish).
@MainActor @Suite(.serialized) struct ControlSnapshotKeyChangeTests {
    private final class NoActions: ControlActionExecutor {
        @MainActor func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { .unknownAction }
    }

    /// Display frames the test runs by hand, so nothing publishes behind its back.
    private final class ManualFrames: ControlFrameSource {
        private let pending = OSAllocatedUnfairLock<[@MainActor @Sendable () -> Void]>(initialState: [])

        func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
            pending.withLock { $0.append(work) }
        }

        /// Runs every scheduled frame, and the ones those schedule, until none is left.
        @MainActor func run() {
            while true {
                let work = pending.withLock { list in
                    defer { list = [] }
                    return list
                }
                if work.isEmpty { return }
                for frame in work { frame() }
            }
        }
    }

    private static func fullPublishes() -> Int {
        DebugTimings.handle([:])["control_publishes"]?.arrayValue?.count ?? 0
    }

    @Test func aKeyOrActivationChangeMapsNoWorkspaceAgain() {
        // AppServices reads NSApp (the key window source): create it first.
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let identity = ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                       processID: getpid())
        let router = ControlRouter(identity: identity, executor: NoActions())
        let frames = ManualFrames()
        let publisher = ControlSnapshotPublisher(router: router, services: services, frames: frames)
        _ = DebugTimings.handle(["clear": .bool(true)])
        publisher.start()
        defer { publisher.stop() }
        frames.run()
        let before = Self.fullPublishes()
        #expect(before >= 1, "start publishes the whole snapshot once")

        // A Cmd-Tab away and back, as AppKit posts it, and a panel taking the keys.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let center = NotificationCenter.default
        for _ in 0..<3 {
            center.post(name: NSWindow.didResignKeyNotification, object: window)
            center.post(name: NSApplication.didResignActiveNotification, object: nil)
            frames.run()
            center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            center.post(name: NSWindow.didBecomeKeyNotification, object: window)
            frames.run()
        }
        #expect(Self.fullPublishes() == before,
                "a key or activation change rebuilt every workspace's control facts (\(Self.fullPublishes() - before) full publishes)")
    }
}
