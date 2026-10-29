import CmuxNextTrace

/// The keys of the process's crash-key page (``CrashKeyPage``) that the owners these slots
/// reach set: the input tap, the window manager and the tab content cache. Each is one or two relaxed stores into
/// the attached page (``page``), nothing before the composition root attaches one.
extension CrashKeySlots {
    /// Names the input event the app dispatched last (``CrashKeySlot/lastInputUptime``): `uptimeSeconds` is
    /// `NSEvent.timestamp` (seconds on `CLOCK_UPTIME_RAW`), stored as nanoseconds on the page's clock.
    @inline(__always)
    public func noteInput(uptimeSeconds: Double) {
        guard uptimeSeconds > 0, uptimeSeconds < 1e9 else { return }
        page.set(.lastInputUptime, UInt64(uptimeSeconds * 1e9))
    }

    /// Names how many windows are open (``CrashKeySlot/windowCount``, a power-of-two bucket).
    public func noteWindows(_ count: Int) {
        page.setCount(.windowCount, count)
    }

    /// Names how many terminal surfaces are live (``CrashKeySlot/terminalCount``, a power-of-two bucket).
    public func noteTerminals(_ count: Int) {
        page.setCount(.terminalCount, count)
    }

    /// Names how many Chromium browsers and WebKit pages are live (``CrashKeySlot/chromiumBrowserCount`` and
    /// ``CrashKeySlot/webKitViewCount``, power-of-two buckets).
    public func noteBrowsers(chromium: Int, webKit: Int) {
        page.setCount(.chromiumBrowserCount, chromium)
        page.setCount(.webKitViewCount, webKit)
    }
}
