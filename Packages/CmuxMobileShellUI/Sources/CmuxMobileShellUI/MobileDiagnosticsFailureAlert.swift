import CmuxMobileSupport
import Foundation

#if canImport(UIKit)
struct MobileDiagnosticsFailureAlert: Identifiable {
    let id = UUID()
    let title = L10n.string(
        "mobile.diagnostics.prepareFailedTitle",
        defaultValue: "Couldn't Prepare Diagnostics"
    )
    let message = L10n.string(
        "mobile.diagnostics.prepareFailedMessage",
        defaultValue: "Try again in a moment."
    )
}
#endif
