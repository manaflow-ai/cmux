import AppKit
import CmuxNextSignposts
import Testing

/// `action.commit` ends at ``CommitBoundary``: right only while every display, layout and commit
/// observer of the turn runs before it. `SignpostsTests` checks a bare test process (Core Animation
/// only); this one boots `NSApplication`, shows a window and dirties its layout and display, so
/// AppKit's own observers (its display cycle) are on the main run loop too, on whichever macOS
/// runs it. The running app reports the same audit through `debug.commit_boundary`.
@MainActor @Suite(.serialized)
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
}
