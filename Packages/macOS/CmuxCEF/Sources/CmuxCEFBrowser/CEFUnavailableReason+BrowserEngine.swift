public import CmuxBrowser
public import CmuxCEF

extension CEFUnavailableReason {
    /// The engine-neutral form of this reason.
    public var browserEngineReason: BrowserEngineUnavailableReason {
        switch self {
        case .notBundled: .notBundled
        case .startFailed(let message): .startFailed(message)
        case .shutDown: .shutDown
        }
    }
}
