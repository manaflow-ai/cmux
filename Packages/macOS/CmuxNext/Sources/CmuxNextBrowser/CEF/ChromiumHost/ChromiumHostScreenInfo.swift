import AppKit

/// The display a hosted page view shows on: what Chrome's page view sends its browser process as
/// `RenderWidgetHostNSViewHost::OnScreenInfosChanged` (content/common/render_widget_host_ns_view.mojom,
/// sent from `-[RenderWidgetHostViewCocoa updateScreenProperties]` in
/// content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm only when the infos differ). In host
/// mode the page's window lives in the Chromium Host and is never ordered in, so its display, and with
/// it the begin-frame rate, the device scale factor and the color space, comes from cmux
/// (plans/cmux-next/chrome-parity/p01-process.md, task 221).
///
/// Only ``displayID`` crosses the wire (``ChromiumHostPageView/pageDisplay``): the fork reads the rest
/// from that display, as Chrome's browser process builds `display::ScreenInfos` from
/// `display::Screen`. The other fields tell when the same display changed under the page (another
/// scale, color profile, refresh rate or work area) so the host places the page again.
nonisolated struct ChromiumHostScreenInfo: Equatable, Sendable {
    /// The display's `CGDirectDisplayID`.
    var displayID: UInt32
    /// The window's backing scale factor, in thousandths.
    var scaleMilli: Int32
    /// FNV-1a over the display's ICC profile, 0 without one.
    var colorSpaceHash: UInt64
    /// `NSScreen.maximumFramesPerSecond`: the rate begin-frames tick at on this display.
    var maximumFramesPerSecond: Int
    /// The display's visible frame in screen points (less the menu bar and the Dock).
    var workArea: CGRect

    /// The first fork API with `cmux_browser_set_page_display` (task 227).
    static let forkAPI: Int32 = 31

    /// `window`'s display, nil while the window is on none.
    @MainActor static func of(_ window: NSWindow) -> ChromiumHostScreenInfo? {
        guard let screen = window.screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return ChromiumHostScreenInfo(
            displayID: number.uint32Value, scaleMilli: Int32((window.backingScaleFactor * 1_000).rounded()),
            colorSpaceHash: screen.colorSpace?.iccProfileData.map(fnv1a) ?? 0,
            maximumFramesPerSecond: screen.maximumFramesPerSecond, workArea: screen.visibleFrame)
    }

    /// FNV-1a 64: a stable hash of a profile of a few kilobytes, read only when the display may have changed.
    static func fnv1a(_ bytes: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

/// What `cmux_shim_browser_set_page_display` takes: the display and the page view's origin on it.
nonisolated struct ChromiumHostPageDisplay: Equatable, Sendable {
    var displayID: UInt32
    /// The page view's bottom left in AppKit screen points.
    var screenX: Double
    var screenY: Double
}
