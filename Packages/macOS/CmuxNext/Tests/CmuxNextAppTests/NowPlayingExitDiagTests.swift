import AppKit
@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Foundation
import Testing

// Diagnostic only (not for merge): which part of the Reduce Motion test stops the main run loop.
@MainActor enum NPExitDiag {
    static var kept: [NSWindow] = []
    static let installed: Void = {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.exit.rawValue, true, 0) { _, _ in
            FileHandle.standardError.write(Data(("NPDIAG runloop exit\n" + Thread.callStackSymbols.prefix(12).joined(separator: "\n") + "\n").utf8))
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        atexit { FileHandle.standardError.write(Data("NPDIAG atexit\n".utf8)) }
    }()

    static func body(orderFront: Bool = true, close: Bool = true, playing: Bool = true, motion: Bool? = true) {
        _ = installed
        _ = NSApplication.shared
        let track = NowPlayingCardTests.track(playing: playing)
        let card = SidebarNowPlayingCardView(frame: NSRect(x: 0, y: 0, width: 216, height: SidebarNowPlayingCardView.height(for: track)))
        let window = NSWindow(contentRect: card.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = card
        if orderFront { window.orderFrontRegardless() }
        card.scrubber.reduceMotionOverride = motion
        card.configure(track)
        card.isHidden = false
        card.layoutSubtreeIfNeeded()
        _ = card.scrubber.accessibilityValue()
        FileHandle.standardError.write(Data("NPDIAG body done\n".utf8))
        if close { window.close() } else { kept.append(window) }
        FileHandle.standardError.write(Data("NPDIAG closed\n".utf8))
    }

    static func warm() async {
        let h = await NowPlayingCardTests().make()
        h.close()
    }

    static func after() async {
        for _ in 0..<40 { try? await Task.sleep(for: .milliseconds(25)) }
        FileHandle.standardError.write(Data("NPDIAG after done\n".utf8))
    }
}

@MainActor @Suite(.serialized) struct NPExitDiagControl {
    @Test func a() async { await NPExitDiag.warm() }
    @Test func b() { NPExitDiag.body() }
    @Test func c() async { await NPExitDiag.after() }
}

@MainActor @Suite(.serialized) struct NPExitDiagNoOrderFront {
    @Test func a() async { await NPExitDiag.warm() }
    @Test func b() { NPExitDiag.body(orderFront: false) }
    @Test func c() async { await NPExitDiag.after() }
}

@MainActor @Suite(.serialized) struct NPExitDiagNoClose {
    @Test func a() async { await NPExitDiag.warm() }
    @Test func b() { NPExitDiag.body(close: false) }
    @Test func c() async { await NPExitDiag.after() }
}

@MainActor @Suite(.serialized) struct NPExitDiagPaused {
    @Test func a() async { await NPExitDiag.warm() }
    @Test func b() { NPExitDiag.body(playing: false) }
    @Test func c() async { await NPExitDiag.after() }
}

@MainActor @Suite(.serialized) struct NPExitDiagGlides {
    @Test func a() async { await NPExitDiag.warm() }
    @Test func b() { NPExitDiag.body(motion: false) }
    @Test func c() async { await NPExitDiag.after() }
}

@MainActor @Suite(.serialized) struct NPExitDiagAsync {
    @Test func a() async { await NPExitDiag.warm() }
    @Test func b() async { NPExitDiag.body() }
    @Test func c() async { await NPExitDiag.after() }
}

@MainActor @Suite(.serialized) struct NPExitDiagColdControl {
    @Test func b() { NPExitDiag.body() }
    @Test func c() async { await NPExitDiag.after() }
}
