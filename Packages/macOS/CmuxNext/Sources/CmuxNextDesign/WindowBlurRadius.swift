public import AppKit
import Darwin

/// The CGS behind-window blur radius of a window
/// (`CGSSetWindowBackgroundBlurRadius`), the blur Ghostty.app and iTerm2
/// put under a translucent window. Set directly with the backdrop's own
/// radius (``WindowBackdrop/windowBlurRadius``), so a theme with its own
/// `background-blur` gets that radius and 0 clears it.
///
/// ```swift
/// WindowBlurRadius.set(backdrop.windowBlurRadius, on: window)
/// ```
@MainActor
public enum WindowBlurRadius {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetRadius = @convention(c) (Int32, Int, Int32) -> Int32

    /// Looked up once; nil (setting does nothing) when the SPI is missing.
    private static let functions: (MainConnection, SetRadius)? = {
        guard let connection = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID"),
              let setRadius = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetWindowBackgroundBlurRadius") else { return nil }
        return (unsafeBitCast(connection, to: MainConnection.self), unsafeBitCast(setRadius, to: SetRadius.self))
    }()

    /// Sets `window`'s blur radius; 0 clears it.
    ///
    /// - Parameter radius: The radius in points, clamped to 0...255.
    /// - Parameter window: A window with a window number.
    public static func set(_ radius: Int, on window: NSWindow) {
        guard let (connection, setRadius) = functions, window.windowNumber > 0 else { return }
        _ = setRadius(connection(), window.windowNumber, Int32(min(max(radius, 0), 255)))
    }
}
