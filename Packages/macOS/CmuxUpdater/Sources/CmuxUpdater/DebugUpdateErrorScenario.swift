public import Foundation
@preconcurrency public import Sparkle

#if DEBUG
/// A synthetic update-error scenario that the debug menu can inject so every error popover
/// variant (title, message, and whether the manual-download button shows) can be previewed
/// without reproducing the real failure.
///
/// Cases map one-to-one to the branches in ``UpdateStateModel/userFacingErrorTitle(for:)`` /
/// ``UpdateStateModel/userFacingErrorMessage(for:)`` / ``UpdateStateModel/manualDownloadURL(for:)``.
public enum DebugUpdateErrorScenario: String, CaseIterable, Hashable, Sendable {
    /// 4005 wrapping the internal IPC-timeout (the wedged-launchd case): "Couldn't Start Updater".
    case installerAgentFailure
    /// 4010 `SUAgentInvalidationError`: also "Couldn't Start Updater".
    case agentInvalidation
    /// Plain 4005 with no agent signal: "Updater Permission Error" + recovery message + download.
    case genericInstallFailure
    /// 4005 wrapping `SUAuthenticationFailure` (4001): must NOT be treated as an agent failure.
    case installFailureWrappingAuth
    /// 2001 `SUDownloadError`: "Couldn't Download Update", offers download.
    case downloadFailure
    /// 1003 `SURunningFromDiskImageError`: keeps "Move into Applications", no download button.
    case diskImageTranslocation
    /// 3001 `SUSignatureError`: signature copy, deliberately no download button.
    case signatureError
    /// Offline `NSURLError`: "No Internet Connection".
    case noInternet

    /// The label shown for this scenario in the debug menu.
    public var menuTitle: String {
        switch self {
        case .installerAgentFailure: return "Installer Agent Failure (4005 + timeout)"
        case .agentInvalidation: return "Agent Invalidation (4010)"
        case .genericInstallFailure: return "Generic Install Failure (4005)"
        case .installFailureWrappingAuth: return "Install Failure / Auth (4005→4001)"
        case .downloadFailure: return "Download Failure (2001)"
        case .diskImageTranslocation: return "Disk Image / Translocated (1003)"
        case .signatureError: return "Signature Error (3001)"
        case .noInternet: return "No Internet"
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
        }
    }
}
#endif
