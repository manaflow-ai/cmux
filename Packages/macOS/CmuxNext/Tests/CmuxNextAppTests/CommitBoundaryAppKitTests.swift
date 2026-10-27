import AppKit
import CmuxNextCompat
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

    /// cmux's own after-commit observers (the watchdog's late stamp, the render pass meter, the cursor
    /// keeper) are block observers at `CFIndex.max`: their dump names only a trampoline, so the audit
    /// knows them by address (`AfterCommitObservers`). An unregistered observer that prints the same is
    /// still late, and one stops counting as cmux's once it is removed.
    @Test func registeredAfterCommitObserversAreNotLate() throws {
        let ours = try #require(CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in })
        let theirs = try #require(CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in })
        defer {
            AfterCommitObservers.remove(ours)
            CFRunLoopObserverInvalidate(ours)
            CFRunLoopObserverInvalidate(theirs)
        }
        func entry(_ observer: CFRunLoopObserver) -> String {
            let address = UInt(bitPattern: Unmanaged.passUnretained(observer).toOpaque())
            return "\"<CFRunLoopObserver 0x\(String(address, radix: 16)) [0x2]>{valid = Yes, activities = 0x20, repeats = Yes, "
                + "order = \(CFIndex.max), callout = __CFRunLoopObserverWithHandlerPerform (0x5), context = <CFRunLoopObserver context 0x0>}\","
        }
        AfterCommitObservers.register(ours)
        #expect(CommitBoundaryAudit(description: "observers = (\n\(entry(ours))\n)").late.isEmpty)
        // Equal entries collapse to one observer; an unregistered one among them keeps it late, in either order.
        #expect(CommitBoundaryAudit(description: "observers = (\n\(entry(ours))\n\(entry(theirs))\n)").late.count == 1)
        #expect(CommitBoundaryAudit(description: "observers = (\n\(entry(theirs))\n\(entry(ours))\n)").late.count == 1)
        AfterCommitObservers.remove(ours)
        #expect(CommitBoundaryAudit(description: "observers = (\n\(entry(ours))\n)").late.count == 1)
    }
}
