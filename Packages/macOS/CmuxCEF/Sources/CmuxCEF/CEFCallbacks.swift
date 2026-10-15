import AppKit
import CoreFoundation
import Foundation

// C entry points the shim calls. `context` is the unretained `CEFRuntime`,
// which lives for the rest of the process once started. Every callback but
// the schedule one arrives on the main thread (CEF's UI thread); off it they
// hop or refuse rather than trap in `assumeIsolated`.

/// `OnScheduleMessagePumpWork`: any thread.
let cefScheduleCallback: CEFShimLibrary.ScheduleFn = { context, delayMilliseconds in
    guard let context else { return }
    let address = UInt(bitPattern: context)
    let deliver: @Sendable () -> Void = {
        MainActor.assumeIsolated {
            CEFRuntime.from(address)?.pump?.request(milliseconds: delayMilliseconds)
        }
    }
    if Thread.isMainThread {
        deliver()
    } else {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, deliver)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}

/// Shim events (main thread). The strings are copied before any hop.
let cefEventCallback: CEFShimLibrary.EventFn = { context, kind, browser, request, a, b, s1, s2 in
    guard let context else { return }
    let event = CEFShimEvent(
        kind: kind, browser: browser, request: request, a: a, b: b,
        s1: s1.map { String(cString: $0) } ?? "", s2: s2.map { String(cString: $0) } ?? ""
    )
    let address = UInt(bitPattern: context)
    guard Thread.isMainThread else {
        DispatchQueue.main.async { MainActor.assumeIsolated { CEFRuntime.from(address)?.handle(event) } }
        return
    }
    MainActor.assumeIsolated { CEFRuntime.from(address)?.handle(event) }
}

/// Before the page sees a key down: app shortcuts win. Returns 1 when consumed.
let cefKeyCallback: CEFShimLibrary.KeyFn = { context, browser, nsEvent in
    guard let context, let nsEvent, Thread.isMainThread else { return 0 }
    let address = UInt(bitPattern: context)
    let eventAddress = UInt(bitPattern: nsEvent)
    return MainActor.assumeIsolated {
        guard let runtime = CEFRuntime.from(address),
              let pointer = UnsafeMutableRawPointer(bitPattern: eventAddress) else { return 0 }
        let event = Unmanaged<NSEvent>.fromOpaque(pointer).takeUnretainedValue()
        return runtime.routeKey(event, browser: browser) ? 1 : 0
    }
}

/// Before a DevTools browser sees a key down; `browser` is the inspected page.
let cefDevToolsKeyCallback: CEFShimLibrary.KeyFn = { context, browser, nsEvent in
    guard let context, let nsEvent, Thread.isMainThread else { return 0 }
    let address = UInt(bitPattern: context)
    let eventAddress = UInt(bitPattern: nsEvent)
    return MainActor.assumeIsolated {
        guard let runtime = CEFRuntime.from(address),
              let pointer = UnsafeMutableRawPointer(bitPattern: eventAddress) else { return 0 }
        let event = Unmanaged<NSEvent>.fromOpaque(pointer).takeUnretainedValue()
        return runtime.routeKey(event, browser: browser) ? 1 : 0
    }
}

/// Chromium wants a window or tab (fork API 8): returns the browser whose
/// window gets it, or 0 to open nothing in Chromium.
let cefWindowRequestCallback: CEFShimLibrary.WindowRequestFn = { context, kind, disposition, source, _, _, _, _, _, _, url, _ in
    guard let context, Thread.isMainThread else { return 0 }
    let address = UInt(bitPattern: context)
    let target = url.map { String(cString: $0) } ?? ""
    return MainActor.assumeIsolated {
        CEFRuntime.from(address)?.windowRequest(kind: kind, disposition: disposition, source: source, url: target) ?? 0
    }
}

/// `CefFocusHandler::OnSetFocus`: only a page cmux is focusing may take focus.
let cefFocusRequestCallback: CEFShimLibrary.FocusRequestFn = { context, browser, _ in
    guard let context, Thread.isMainThread else { return 0 }
    let address = UInt(bitPattern: context)
    return MainActor.assumeIsolated {
        CEFRuntime.from(address)?.browser(id: browser)?.isGrantingFocus == true ? 1 : 0
    }
}
