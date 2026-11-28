#if DEBUG
import Foundation
@preconcurrency import Sparkle

/// A synthetic update-error scenario that the debug menu can inject so every error popover
/// variant can be previewed without reproducing the real failure.
public enum DebugUpdateErrorScenario: String, CaseIterable, Hashable, Sendable {
    /// Sparkle installation failure wrapping its internal updater-agent timeout.
    case installerAgentFailure
    /// Sparkle updater-agent invalidation.
    case agentInvalidation
    /// Generic Sparkle installation failure with no nested agent failure.
    case genericInstallFailure
    /// Sparkle installation failure wrapping an authorization failure.
    case installFailureWrappingAuth
    /// Sparkle update download failure.
    case downloadFailure
    /// The app is running from a translocated disk image.
    case diskImageTranslocation
    /// Sparkle could not verify the update signature.
    case signatureError
    /// The update server is unreachable because the network is offline.
    case noInternet
    /// cmux accepted an install but never reached the download callback.
    case installDidNotStart
    /// Sparkle did not become ready for a foreground check before the deadline.
    case updaterNotReady

    /// The label shown for this scenario in the debug menu.
    public var menuTitle: String {
        switch self {
        case .installerAgentFailure:
            return String(localized: "update.debug.error.installerAgentFailure", defaultValue: "Installer Agent Failure (4005 + timeout)")
        case .agentInvalidation:
            return String(localized: "update.debug.error.agentInvalidation", defaultValue: "Agent Invalidation (4010)")
        case .genericInstallFailure:
            return String(localized: "update.debug.error.genericInstallFailure", defaultValue: "Generic Install Failure (4005)")
        case .installFailureWrappingAuth:
            return String(localized: "update.debug.error.installFailureWrappingAuth", defaultValue: "Install Failure / Auth (4005→4001)")
        case .downloadFailure:
            return String(localized: "update.debug.error.downloadFailure", defaultValue: "Download Failure (2001)")
        case .diskImageTranslocation:
            return String(localized: "update.debug.error.diskImageTranslocation", defaultValue: "Disk Image / Translocated (1003)")
        case .signatureError:
            return String(localized: "update.debug.error.signatureError", defaultValue: "Signature Error (3001)")
        case .noInternet:
            return String(localized: "update.debug.error.noInternet", defaultValue: "No Internet")
        case .installDidNotStart:
            return String(
                localized: "update.debug.error.installDidNotStart",
                defaultValue: "Install Didn’t Start (watchdog)"
            )
        case .updaterNotReady:
            return String(
                localized: "update.debug.error.updaterNotReady",
                defaultValue: "Updater Not Ready (readiness timeout)"
            )
        }
    }

    /// Builds the synthetic error for this scenario.
    var error: NSError {
        switch self {
        case .installerAgentFailure:
            let underlying = NSError(domain: SUSparkleErrorDomain, code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Timeout: agent connection was never initiated",
            ])
            return NSError(domain: SUSparkleErrorDomain, code: 4005, userInfo: [
                NSLocalizedDescriptionKey: "An error occurred while running the updater. Please try again later.",
                NSLocalizedFailureReasonErrorKey: "The remote port connection was invalidated from the updater.",
                NSUnderlyingErrorKey: underlying,
            ])
        case .agentInvalidation:
            return NSError(domain: SUSparkleErrorDomain, code: 4010, userInfo: [
                NSLocalizedDescriptionKey: "The updater agent was invalidated.",
            ])
        case .genericInstallFailure:
            return NSError(domain: SUSparkleErrorDomain, code: 4005, userInfo: [
                NSLocalizedDescriptionKey: "The installation failed.",
            ])
        case .installFailureWrappingAuth:
            let underlying = NSError(domain: SUSparkleErrorDomain, code: 4001, userInfo: [
                NSLocalizedDescriptionKey: "Authorization failed.",
            ])
            return NSError(domain: SUSparkleErrorDomain, code: 4005, userInfo: [
                NSLocalizedDescriptionKey: "An error occurred while installing the update.",
                NSUnderlyingErrorKey: underlying,
            ])
        case .downloadFailure:
            return NSError(domain: SUSparkleErrorDomain, code: 2001, userInfo: [
                NSLocalizedDescriptionKey: "The update download failed.",
            ])
        case .diskImageTranslocation:
            return NSError(domain: SUSparkleErrorDomain, code: 1003, userInfo: [
                NSLocalizedDescriptionKey: "Running from a disk image.",
            ])
        case .signatureError:
            return NSError(domain: SUSparkleErrorDomain, code: 3001, userInfo: [
                NSLocalizedDescriptionKey: "The update signature is invalid.",
            ])
        case .noInternet:
            return NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [
                NSLocalizedDescriptionKey: "The Internet connection appears to be offline.",
            ])
        case .installDidNotStart:
            return NSError(domain: UpdateStateModel.updateErrorDomain, code: UpdateStateModel.installDidNotStartCode, userInfo: [
                NSLocalizedDescriptionKey: String(
                    localized: "update.error.didNotStart.message",
                    defaultValue: "cmux couldn’t start the update. Check your internet connection and try again."
                ),
            ])
        case .updaterNotReady:
            return NSError(domain: UpdateStateModel.updateErrorDomain, code: UpdateStateModel.updaterNotReadyCode, userInfo: [
                NSLocalizedDescriptionKey: String(
                    localized: "update.error.notReady",
                    defaultValue: "Updater is still starting. Try again in a moment."
                ),
            ])
        }
    }
}
#endif
