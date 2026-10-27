public import AppKit
import ObjectiveC

/// The window schedulers: one per window, made on first use, kept alive by its window and dropped with it.
extension FrameScheduler {
    private static var windows: [ObjectIdentifier: WeakScheduler] = [:]
    private static var associationKey: UInt8 = 0

    /// `window`'s scheduler, created on first use and dropped with the window.
    public static func forWindow(_ window: NSWindow) -> FrameScheduler {
        let key = ObjectIdentifier(window)
        if let scheduler = windows[key]?.value, scheduler.window === window { return scheduler }
        windows = windows.filter { $0.value.value?.window != nil }
        let scheduler = FrameScheduler(name: "window \(window.windowNumber)", host: .window(window), displays: appDisplays, budget: nil)
        if let energy = app.energy { scheduler.follow(energy) } // its ambient clients follow the app's saver
        windows[key] = WeakScheduler(value: scheduler)
        // The window keeps its scheduler alive.
        objc_setAssociatedObject(window, &FrameScheduler.associationKey, scheduler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        // A window's late frames hold work like the app's (RenderStarvationGuard/watch(_:)).
        app.starvation?.watch(scheduler)
        // A subscribed scheduler is held by its display: let go of it when the window closes.
        // The window's one observer per notice (WindowEvents), as Chromium's NSWindow delegate tells the widget's
        // observers (components/remote_cocoa/app_shim/views_nswindow_delegate.mm): no node, it decides for the window.
        let events = WindowEvents.of(window)
        scheduler.closeObserver = events.subscribe(NSWindow.willCloseNotification, owner: "FrameScheduler.close") { [weak scheduler] in
            scheduler?.invalidate()
        }
        // It ticks on the display the window is on: the window going to another screen moves it there.
        scheduler.screenFamily = WindowScreenFamily(window: window, scheduler: scheduler)
        // An occluded window's animations wait off the link (FrameScheduler+Occlusion.swift).
        scheduler.follow(WindowOcclusionFamily.of(window))
        return scheduler
    }

    /// The scheduler of `view`'s window, or ``app`` while it has none.
    public static func forView(_ view: NSView) -> FrameScheduler {
        view.window.map(forWindow) ?? app
    }

    /// Every live scheduler (debug.wakeups).
    public static var all: [FrameScheduler] {
        [app] + windows.values.compactMap(\.value)
    }

    private struct WeakScheduler {
        weak var value: FrameScheduler?
    }
}
