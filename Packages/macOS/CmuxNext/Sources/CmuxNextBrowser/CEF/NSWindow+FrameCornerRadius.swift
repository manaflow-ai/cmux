public import AppKit
import CmuxNextDesign

extension NSWindow {
    /// Radius of this window's own corners: the one AppKit draws
    /// (`Metrics.drawnWindowCornerRadius(reported:macOSMajor:)`, from the
    /// private `_cornerRadius`, read only when present). Zero in fullscreen and for
    /// borderless windows. Chrome inset from the window's edges rounds
    /// concentrically with it (`Metrics.mainPaneCornerRadius(windowCornerRadius:)`),
    /// and a Chromium page masks itself to it.
    public var frameCornerRadius: CGFloat {
        if styleMask.contains(.fullScreen) || !styleMask.contains(.titled) { return 0 }
        let selector = NSSelectorFromString("_cornerRadius")
        let reported = responds(to: selector) ? (value(forKey: "_cornerRadius") as? NSNumber).map { CGFloat($0.doubleValue) } : nil
        return Metrics.drawnWindowCornerRadius(reported: reported, macOSMajor: Self.runningMacOSMajor)
    }

    /// The running macOS major version, read once (it cannot change while the app runs).
    private static let runningMacOSMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
}
