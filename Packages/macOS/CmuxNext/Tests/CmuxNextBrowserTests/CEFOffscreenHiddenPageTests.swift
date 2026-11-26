import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import CmuxNextWakeupsTestSupport
import IOSurface
import Testing

/// Off-screen pages (approach 5): a window drag resizes every page view in the window's panes, the hidden tab of each
/// pane too. A hidden page never paints, so a hidden page that joined the window's resize fence held it to its deadline
/// on every step, whatever the shown pages did (other-Mac run osr-tr-base-2, three panes with a hidden tab each: 955 of
/// 955 window fences expired, none released by the pages). A page that is not drawing keeps its size, joins no fence
/// and is asked for no frame; the size goes to Chromium when the page is shown.
@MainActor
@Suite(.serialized, .closesItsWindows) struct CEFOffscreenHiddenPageTests {
    /// The shim's calls, without Chromium: `wasResized` counted per browser, the rest do nothing.
    nonisolated enum Shim {
        nonisolated(unsafe) static var resized: [Int32: Int] = [:]

        static var calls: CEFOffscreenShim {
            let fns: [String: UnsafeMutableRawPointer] = [
                "enable": ptr({ (_: Int32, _: Int32) in } as @convention(c) (Int32, Int32) -> Void),
                "set_handlers": ptr({ (_: UnsafeRawPointer?, _: UnsafeMutableRawPointer?) in }
                    as @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void),
                "create": ptr({ (_: Int32, _: UnsafeMutableRawPointer?, _: Int32, _: Int32, _: UnsafePointer<CChar>?,
                                 _: UnsafePointer<CChar>?, _: Int32) -> Int32 in 0 }
                    as @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?,
                                       UnsafePointer<CChar>?, Int32) -> Int32),
                "is_offscreen": ptr({ (_: Int32) -> Int32 in 1 } as @convention(c) (Int32) -> Int32),
                "was_resized": ptr({ (browser: Int32) in Shim.resized[browser, default: 0] += 1 }
                    as @convention(c) (Int32) -> Void),
                "was_hidden": ptr({ (_: Int32, _: Int32) in } as @convention(c) (Int32, Int32) -> Void),
                "screen_info_changed": ptr({ (_: Int32) in } as @convention(c) (Int32) -> Void),
                "invalidate": ptr({ (_: Int32) in } as @convention(c) (Int32) -> Void),
                "set_frame_rate": ptr({ (_: Int32, _: Int32) in } as @convention(c) (Int32, Int32) -> Void),
                "begin_frame": ptr({ (_: Int32) in } as @convention(c) (Int32) -> Void),
                "mouse": ptr({ (_: Int32, _: Int32, _: Int32, _: Int32, _: UInt32, _: Int32, _: Int32) in }
                    as @convention(c) (Int32, Int32, Int32, Int32, UInt32, Int32, Int32) -> Void),
                "wheel": ptr({ (_: Int32, _: Int32, _: Int32, _: UInt32, _: Int32, _: Int32) in }
                    as @convention(c) (Int32, Int32, Int32, UInt32, Int32, Int32) -> Void),
                "key": ptr({ (_: Int32, _: Int32, _: UInt32, _: Int32, _: UInt16, _: UInt16) in }
                    as @convention(c) (Int32, Int32, UInt32, Int32, UInt16, UInt16) -> Void),
                "ime_set_composition": ptr({ (_: Int32, _: UnsafePointer<CChar>?, _: Int32, _: Int32, _: Int32, _: Int32) in }
                    as @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32, Int32, Int32) -> Void),
                "ime_commit": ptr({ (_: Int32, _: UnsafePointer<CChar>?, _: Int32, _: Int32, _: Int32) in }
                    as @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32, Int32) -> Void),
                "ime_finish": ptr({ (_: Int32, _: Int32) in } as @convention(c) (Int32, Int32) -> Void),
                "ime_cancel": ptr({ (_: Int32) in } as @convention(c) (Int32) -> Void),
                "edit": ptr({ (_: Int32, _: Int32) in } as @convention(c) (Int32, Int32) -> Void),
                "drag": ptr({ (_: Int32, _: Int32, _: Int32, _: Int32, _: UInt32, _: UnsafePointer<UnsafePointer<CChar>?>?,
                               _: Int32, _: Int32) -> Int32 in 0 }
                    as @convention(c) (Int32, Int32, Int32, Int32, UInt32, UnsafePointer<UnsafePointer<CChar>?>?, Int32,
                                       Int32) -> Int32),
                "counters": ptr({ (_: UnsafeMutablePointer<UInt64>?, _: Int32) in }
                    as @convention(c) (UnsafeMutablePointer<UInt64>?, Int32) -> Void),
            ]
            return CEFOffscreenShim(lookup: { fns[String($0.dropFirst("cmux_shim_osr_".count))] })!
        }

        private static func ptr<T>(_ fn: T) -> UnsafeMutableRawPointer { unsafeBitCast(fn, to: UnsafeMutableRawPointer.self) }
    }

    /// The fences made, as receive rights this test keeps, so the app's send rights on them can be counted: the render
    /// server holds the window's commit exactly while a send right lives (``CEFResizeFence/createFencePort(layer:)``).
    final class Ports {
        var made: [mach_port_t] = []
        func make() -> mach_port_t? {
            var name = mach_port_t(MACH_PORT_NULL)
            guard mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &name) == KERN_SUCCESS,
                  mach_port_insert_right(mach_task_self_, name, name, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))
                  == KERN_SUCCESS else { return nil }
            made.append(name)
            return name
        }

        func sendRights(_ port: mach_port_t) -> mach_port_urefs_t {
            var refs: mach_port_urefs_t = 0
            _ = mach_port_get_refs(mach_task_self_, port, MACH_PORT_RIGHT_SEND, &refs)
            return refs
        }
    }

    let ports = Ports()
    /// The fences' own deadlines never come: what releases a fence here is the pages.
    let clock = ManualClock()

    /// A pane with a shown page and a hidden tab's page, in a borderless window off screen; the fences are this test's.
    func makePane() -> (shown: CEFOffscreenPageView, hidden: CEFOffscreenPageView, window: NSWindow) {
        Shim.resized = [:]
        let ports = ports
        CEFRuntime.shared.offscreenPages.fencesForTesting = CEFResizeFences(clock: clock, makePort: { _ in ports.make() })
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.wantsLayer = true
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        pane.wantsLayer = true
        window.contentView?.addSubview(pane)
        let shown = CEFOffscreenPageView(browser: 9_001, calls: Shim.calls)
        let hidden = CEFOffscreenPageView(browser: 9_002, calls: Shim.calls)
        hidden.isHidden = true
        for page in [shown, hidden] {
            pane.addSubview(page)
            page.frame = pane.bounds
        }
        endTurn()
        return (shown, hidden, window)
    }

    /// Runs the blocks queued for the end of this turn and the turn's after-commit work (a run-loop pass).
    func endTurn() { CFRunLoopRunInMode(.defaultMode, 0.005, false) }

    /// A frame of `page` at its current size, as the shim hands it over.
    func paint(_ page: CEFOffscreenPageView) {
        let width = Int((page.pageSize.width * page.backingScale).rounded())
        let height = Int((page.pageSize.height * page.backingScale).rounded())
        let properties: [String: Int] = [kIOSurfaceWidth as String: width, kIOSurfaceHeight as String: height,
                                         kIOSurfaceBytesPerElement as String: 4,
                                         kIOSurfacePixelFormat as String: 0x4247_5241]  // 'BGRA'
        let surface = IOSurfaceCreate(properties as CFDictionary)!
        page.show(surface, width: width, height: height, popup: false)
    }

    @Test func aWindowStepsFenceGoesWhenTheShownPagePaintsNotAtItsDeadline() {
        let (shown, hidden, window) = makePane()
        defer {
            window.closeAfterTest()
            CEFRuntime.shared.offscreenPages.fencesForTesting = nil
        }
        // One step of a window drag: both pages of the pane take the new size in one turn.
        let made = ports.made.count
        let hiddenResized = Shim.resized[hidden.browser, default: 0]
        for page in [shown, hidden] { page.setFrameSize(NSSize(width: 360, height: 280)) }
        #expect(ports.made.count == made + 1, "the step opened no fence for the shown page")
        guard let fence = ports.made.last else { return }
        endTurn()
        #expect(ports.sendRights(fence) == 1, "the step's commit went before the shown page's frame at the new size")
        paint(shown)
        endTurn()
        #expect(ports.sendRights(fence) == 0,
                "the step's fence still holds the window's commit after the shown page painted: a page that is not drawing joined it")
        #expect(Shim.resized[hidden.browser, default: 0] == hiddenResized, "the hidden page was resized while hidden")
    }

    @Test func aHiddenPagesSizeGoesToChromiumWhenItIsShown() {
        let (shown, hidden, window) = makePane()
        defer {
            window.closeAfterTest()
            CEFRuntime.shared.offscreenPages.fencesForTesting = nil
        }
        let resizedBefore = Shim.resized[hidden.browser, default: 0]
        let sizeBefore = hidden.pageSize
        hidden.setFrameSize(NSSize(width: 360, height: 280))
        shown.setFrameSize(NSSize(width: 360, height: 280))
        endTurn()
        #expect(hidden.pageSize == sizeBefore, "Chromium got a hidden page's new size")
        #expect(Shim.resized[hidden.browser, default: 0] == resizedBefore, "a hidden page was resized")
        // The tab is shown: its page takes the size it was given while hidden, once.
        hidden.isHidden = false
        #expect(hidden.pageSize == CGSize(width: 360, height: 280), "the shown page kept the size it had when hidden")
        #expect(Shim.resized[hidden.browser, default: 0] == resizedBefore + 1)
    }
}
