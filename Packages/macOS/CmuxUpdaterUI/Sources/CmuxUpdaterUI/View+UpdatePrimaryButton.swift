import SwiftUI

extension View {
    /// `.borderedProminent` that keeps its accent bezel and label when the popover's window is not key.
    ///
    /// The update popover usually opens without becoming the key window, so SwiftUI reports an
    /// inactive control state. AppKit then draws the inactive gray bezel under the prominent
    /// label and the primary action ("Install and Relaunch") shows as an empty gray box (#18687).
    /// Same treatment as the Cloud enablement buttons (`cloudProminentButtonStyle`).
    func updatePrimaryButtonStyle() -> some View {
        buttonStyle(.borderedProminent)
            .environment(\.controlActiveState, .key)
    }
}
