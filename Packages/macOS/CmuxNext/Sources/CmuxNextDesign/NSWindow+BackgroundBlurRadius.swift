public import AppKit
import Darwin

extension NSWindow {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetRadius = @convention(c) (Int32, UInt32, Int32) -> Int32

    /// Sets the window's CGS behind-window blur radius
    /// (`CGSSetWindowBackgroundBlurRadius`), the blur Ghostty.app and iTerm2
    /// put under a translucent window; 0 clears it. Called with the
    /// backdrop's own radius (``WindowBackdrop/windowBlurRadius``), so a
    /// theme with its own `background-blur` gets that radius. Does nothing
    /// when the SPI is missing or the window has no window number.
    ///
    /// ```swift
    /// window.setBackgroundBlurRadius(backdrop.windowBlurRadius)
    /// ```
    ///
    /// - Parameter radius: The radius in points, clamped to 0...255.
    @MainActor
    public func setBackgroundBlurRadius(_ radius: Int) {
        // SAFETY: -2 is RTLD_DEFAULT (dlfcn.h), the handle dlsym takes to search every loaded image; it is never read.
        let defaultHandle = unsafe UnsafeMutableRawPointer(bitPattern: -2)
        // SAFETY: dlsym reads the NUL-terminated symbol names, literals valid for the call.
        guard windowNumber > 0,
              let connection = unsafe dlsym(defaultHandle, "CGSMainConnectionID"),
              let setRadius = unsafe dlsym(defaultHandle, "CGSSetWindowBackgroundBlurRadius") else { return }
        // SAFETY: each symbol is the SkyLight function of that name, called with its C type:
        // CGSConnectionID CGSMainConnectionID(void) and
        // CGError CGSSetWindowBackgroundBlurRadius(CGSConnectionID, CGSWindowID, int).
        let mainConnection = unsafe unsafeBitCast(connection, to: MainConnection.self)
        _ = unsafe unsafeBitCast(setRadius, to: SetRadius.self)(mainConnection(), UInt32(clamping: windowNumber),
                                                                 Int32(min(max(radius, 0), 255)))
    }
}
