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
}
#endif
