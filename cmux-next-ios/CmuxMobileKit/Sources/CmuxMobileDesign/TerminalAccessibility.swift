#if os(iOS)
import Foundation

/// Localized accessibility strings shared by terminal controls.
public enum CmuxMobileTerminalAccessibility {
    public static var cancelSending: String {
        String(localized: "terminal.composer.cancelSending", defaultValue: "Cancel sending", bundle: .module)
    }
}
#endif
