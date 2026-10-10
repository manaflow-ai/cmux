public import AppKit
import Darwin

extension NSWindow {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetRadius = @convention(c) (Int32, Int, Int32) -> Int32

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
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        guard windowNumber > 0,
              let connection = dlsym(defaultHandle, "CGSMainConnectionID"),
              let setRadius = dlsym(defaultHandle, "CGSSetWindowBackgroundBlurRadius") else { return }
        let mainConnection = unsafeBitCast(connection, to: MainConnection.self)
        _ = unsafeBitCast(setRadius, to: SetRadius.self)(mainConnection(), windowNumber, Int32(min(max(radius, 0), 255)))
    }
}
