import Foundation

#if DEBUG
/// User-facing strings of remote tabs (Localizable.xcstrings of this module).
public nonisolated struct RemoteBrowserStrings {
    public nonisolated init() {}
    /// The refusal for an address that is not a loopback host port.
    public static func addressNotRecognized(_ address: String) -> String {
        String(format: String(localized: "remoteBrowser.refusal.address", defaultValue: "Not a loopback host address: %@", bundle: .module), address)
    }

    /// The refusal when this build has no remote browser host; `variable`
    /// is the override environment variable.
    public static func hostNotInBuild(_ variable: String) -> String {
        String(format: String(localized: "remoteBrowser.localHost.missing",
                              defaultValue: "This build has no remote browser host. Set %@ to a cmux-remote-browser-host app.",
                              bundle: .module), variable)
    }

    /// The alert detail for a local host that did not start: a timeout, an
    /// exit before it listened, or a launch error.
    public static func hostFailure(_ error: any Error) -> String {
        switch error {
        case let LocalRemoteBrowserHost.Failure.timedOut(seconds, log):
            String(format: String(localized: "remoteBrowser.localHost.timedOut",
                                  defaultValue: "The host did not get ready within %1$d seconds and was stopped. Its log is at %2$@.",
                                  bundle: .module), seconds, log.path)
        case let LocalRemoteBrowserHost.Failure.exitedBeforeListening(log):
            String(format: String(localized: "remoteBrowser.localHost.exited",
                                  defaultValue: "The host stopped before it was ready. Its log is at %@.", bundle: .module), log.path)
        default:
            String(describing: error)
        }
    }

    /// The alert title when a local host exits before it listens.
    public static var hostDidNotStart: String {
        String(localized: "remoteBrowser.localHost.failed", defaultValue: "The remote browser host did not start", bundle: .module)
    }

    /// The title of a tab that shows no page (`RemoteBrowserFailure`).
    public static var failureTitle: String {
        String(localized: "remoteBrowser.failure.title", defaultValue: "Not Connected", bundle: .module)
    }

    /// What a failed tab shows in its page area; `address` is the host's.
    public static func failure(_ failure: RemoteBrowserFailure, address: String) -> String {
        switch failure {
        case .refused(hadSecret: false):
            String(format: String(localized: "remoteBrowser.failure.refused",
                                  defaultValue: "The remote browser host at %@ refused this tab. It serves only a viewer that has its per-launch secret. Open the tab again with the host's secret file, or use Open Remote Browser Tab (Local Host).",
                                  bundle: .module), address)
        case .refused(hadSecret: true):
            String(format: String(localized: "remoteBrowser.failure.refusedSecret",
                                  defaultValue: "The remote browser host at %@ refused this tab: the secret is not the host's secret.",
                                  bundle: .module), address)
        case .unreachable:
            String(format: String(localized: "remoteBrowser.failure.unreachable",
                                  defaultValue: "No remote browser host answers at %@.", bundle: .module), address)
        case .connectionLost:
            String(format: String(localized: "remoteBrowser.failure.connectionLost",
                                  defaultValue: "The connection to the remote browser host at %@ closed.", bundle: .module), address)
        case .hostEnded:
            String(format: String(localized: "remoteBrowser.failure.hostEnded",
                                  defaultValue: "The remote browser host at %@ ended this tab.", bundle: .module), address)
        case let .secretFile(reason, path):
            secretFile(reason, path: path)
        }
    }

    /// Why the secret file at `path` was not used (the tab's text, and the
    /// refusal of Open Remote Browser Tab).
    public static func secretFile(_ failure: RemoteBrowserSecretFile.Failure, path: String) -> String {
        switch failure {
        case .missing:
            String(format: String(localized: "remoteBrowser.secretFile.missing",
                                  defaultValue: "The secret file %@ does not exist.", bundle: .module), path)
        case .notRegularFile:
            String(format: String(localized: "remoteBrowser.secretFile.notRegular",
                                  defaultValue: "The secret file %@ is not a regular file.", bundle: .module), path)
        case .notOwned:
            String(format: String(localized: "remoteBrowser.secretFile.notOwned",
                                  defaultValue: "The secret file %@ belongs to another user.", bundle: .module), path)
        case .notPrivate:
            String(format: String(localized: "remoteBrowser.secretFile.notPrivate",
                                  defaultValue: "Other users can read the secret file %@. Make it private with chmod 600.", bundle: .module), path)
        case .empty:
            String(format: String(localized: "remoteBrowser.secretFile.empty",
                                  defaultValue: "The secret file %@ has no secret on its first line.", bundle: .module), path)
        case .unreadable:
            String(format: String(localized: "remoteBrowser.secretFile.unreadable",
                                  defaultValue: "Cannot read the secret file %@.", bundle: .module), path)
        }
    }
}
#endif
