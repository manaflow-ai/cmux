import AppKit
import CmuxNextTestSupport
import Testing

/// The window census tags each window with the suite and test that opened it, and
/// `.closesItsWindows` closes and names what a suite left open (CmuxNextTestWindowCensus.c,
/// WindowLeakCheck.swift). Serialized: the check reads this suite's windows while it runs.
@Suite(.serialized, .closesItsWindows)
struct WindowLeakCheckTests {
    private static let suite = "CmuxNextAppTests.WindowLeakCheckTests"

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.title = "leak check"
        return window
    }

    @Test func aWindowIsTaggedWithTheSuiteAndTestThatOpenedIt() {
        #expect(WindowLeaks.isInstalled)
        let window = makeWindow()
        defer { window.close() }
        let owner = WindowLeaks.owner(of: window)
        #expect(owner?.suite == Self.suite)
        #expect(owner?.test == "aWindowIsTaggedWithTheSuiteAndTestThatOpenedIt()")
    }

    @Test func aPanelIsTaggedToo() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        #expect(WindowLeaks.owner(of: panel)?.suite == Self.suite)
    }

    @Test func theCheckClosesAndNamesAWindowItsSuiteLeftOpen() async {
        let window = makeWindow()
        window.orderFront(nil)
        let leaked = await WindowLeaks.closeLeaks(ofSuite: Self.suite)
        #expect(leaked.map(\.test) == ["theCheckClosesAndNamesAWindowItsSuiteLeftOpen()"])
        #expect(leaked.first?.title == "leak check")
        #expect(WindowLeaks.wasClosed(window))
        #expect(!window.isVisible)
        let message = WindowLeaks.leakMessage(suite: Self.suite, leaked: leaked)
        #expect(message.hasPrefix("\(Self.suite) left 1 window open"))
    }

    @Test func aWindowItsTestClosedIsNotALeakEvenWhileStillHeld() async {
        let window = makeWindow()
        window.orderFront(nil)
        window.close()
        #expect(WindowLeaks.wasClosed(window))
        #expect(await WindowLeaks.closeLeaks(ofSuite: Self.suite).isEmpty)
    }

    @Test func appKitsOwnWindowClassesAreNotLeaksButOursAndPlainOnesAre() {
        let window = makeWindow()
        defer { window.close() }
        #expect(!WindowLeaks.isAppKitsOwn(window))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        #expect(!WindowLeaks.isAppKitsOwn(panel))
        let ours = LeakCheckTestWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        ours.isReleasedWhenClosed = false
        defer { ours.close() }
        #expect(!WindowLeaks.isAppKitsOwn(ours))
        // A private AppKit window class, as AppKit's text input window is.
        if let appKitClass = NSClassFromString("TUINSWindow") as? NSWindow.Type {
            let appKits = appKitClass.init(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
            appKits.isReleasedWhenClosed = false
            defer { appKits.close() }
            #expect(WindowLeaks.isAppKitsOwn(appKits))
        }
    }

    @Test func orderingAClosedWindowBackInReopensIt() {
        let window = makeWindow()
        window.orderFront(nil)
        window.close()
        window.orderFront(nil)
        #expect(!WindowLeaks.wasClosed(window))
        window.close()
        #expect(WindowLeaks.wasClosed(window))
    }
}

private final class LeakCheckTestWindow: NSWindow {}
