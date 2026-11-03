public import AppKit
import CmuxNextDesign

extension NSWindow {
    /// Radius of this window's own corners: AppKit's value when it reports
    /// one (`_cornerRadius`, private, read only when present), else the
    /// macOS 26 titled-window default. Zero in fullscreen and for
    /// borderless windows. Chrome inset from the window's edges rounds
    /// concentrically with it (`Metrics.mainPaneCornerRadius(windowCornerRadius:)`),
    /// and a Chromium page masks itself to it.
    public var frameCornerRadius: CGFloat {
        if styleMask.contains(.fullScreen) || !styleMask.contains(.titled) { return 0 }
        let selector = NSSelectorFromString("_cornerRadius")
        if responds(to: selector), let value = value(forKey: "_cornerRadius") as? NSNumber {
            return CGFloat(value.doubleValue)
        }
        return Self.fallbackFrameCornerRadius
    }

    /// The macOS 26 titled-window corner radius, when AppKit reports none (the tabs are
    /// concentric with it, `Metrics.tabCornerRadius`).
    private static var fallbackFrameCornerRadius: CGFloat { Metrics.standardWindowCornerRadius }
}
