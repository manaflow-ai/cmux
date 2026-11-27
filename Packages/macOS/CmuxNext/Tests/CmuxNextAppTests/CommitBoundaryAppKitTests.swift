import AppKit
import CmuxNextCompat
import CmuxNextSignposts
import CmuxNextTestSupport
import Testing

/// `action.commit` ends at ``CommitBoundary``: right only while every display, layout and commit
/// observer of the turn runs before it. `SignpostsTests` checks a bare test process (Core Animation
/// only); this one boots `NSApplication`, shows a window and dirties its layout and display, so
/// AppKit's own observers (its display cycle) are on the main run loop too, on whichever macOS
/// runs it. The running app reports the same audit through `debug.commit_boundary`.
@MainActor @Suite(.serialized, .closesItsWindows)
struct CommitBoundaryAppKitTests {
    @Test func appKitAndCoreAnimationObserversRunBeforeTheBoundary() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSView(frame: window.contentLayoutRect)
        view.wantsLayer = true
        window.contentView = view
        window.orderFrontRegardless()
        view.needsLayout = true
        view.needsDisplay = true
        view.layer?.opacity = 0.5
        let audit = CommitBoundaryAudit.mainRunLoop()
        let macOS = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        // The whole dump in the log, so each fleet major's real observers can be read (and the
        // display-cycle expectation below updated from them).
        print("COMMIT-BOUNDARY-DUMP macOS \(macOS): \(audit.observers.map(\.description).joined(separator: "\n"))")
        try #require(!audit.coreAnimation.isEmpty, "no Core Animation commit observer: \(audit.observers)")
        #expect(audit.late.isEmpty, "observers after the boundary on \(ProcessInfo.processInfo.operatingSystemVersionString): \(audit.late)")
    }

    /// cmux's own after-commit observers (the watchdog's late stamp, the render pass meter, the cursor
    /// keeper) run past the boundary and draw nothing. A block observer's dump names only a trampoline,
    /// so they describe themselves through their context (`MainRunLoopObserver.afterCommitObserver`):
    /// the audit reads that from their real `CFCopyDescription`, while a block observer in the same place
    /// is still late.
    @Test func observersThatSayTheyDrawNothingAreNotLate() throws {
        var calls = 0
        let ours = MainRunLoopObserver.afterCommitObserver(activities: .beforeWaiting, order: CFIndex.max) { _ in calls += 1 }
        let theirs = try #require(CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in })
        defer {
            CFRunLoopObserverInvalidate(ours)
            CFRunLoopObserverInvalidate(theirs)
        }
        let entry = { (observer: CFRunLoopObserver) in "\"\(CFCopyDescription(observer) as String)\"," }
        #expect(entry(ours).contains("context = \(MainRunLoopObserver.drawsNothingAfterCommitContext)"), "\(entry(ours))")
        let audit = CommitBoundaryAudit(description: "observers = (\n\(entry(ours))\n\(entry(theirs))\n)")
        #expect(audit.observers.count == 2, "\(audit.observers)")
        #expect(audit.late.count == 1, "\(audit.late)")
        #expect(audit.late.allSatisfy { !$0.drawsNothingAfterCommit })
        // The handler still runs: the context carries it. A private mode with one timer turns the run
        // loop through a pass (and its before-waiting) without running any other main-thread work.
        let mode = CFRunLoopMode("cmux.CommitBoundaryAppKitTests" as CFString)
        CFRunLoopAddObserver(CFRunLoopGetMain(), ours, mode)
        let timer = try #require(CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.01, 0, 0, 0) { _ in })
        defer { CFRunLoopTimerInvalidate(timer) }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, mode)
        _ = CFRunLoopRunInMode(mode, 0.5, true)
        #expect(calls > 0, "the observer's handler never ran")
    }
}
