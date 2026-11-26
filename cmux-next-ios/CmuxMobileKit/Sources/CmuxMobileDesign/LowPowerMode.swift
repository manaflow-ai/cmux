import Foundation

/// Whether the phone is in Low Power Mode: what the app turns off then (haptics) reads it here.
/// A DEBUG launch argument, `-cmux-mobile-low-power`, holds it on in the simulator, which has no
/// Low Power Mode switch, so a UI test runs the app's Low Power path
/// (ComposerTypingLagUITests; the simulator draws at 60 Hz, the rate Low Power Mode caps a
/// ProMotion phone to).
public enum CmuxMobileLowPowerMode {
    public static var isOn: Bool {
        #if DEBUG
        if forced { return true }
        #endif
        return ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    #if DEBUG
    private static let forced = CommandLine.arguments.contains("-cmux-mobile-low-power")
    #endif
}
