/// Where the install of the pinned Chromium runtime pack stands
/// (``ChromiumRuntimeInstaller/states()``).
public enum ChromiumRuntimeInstallState: Sendable, Equatable {
    /// Nothing has started yet.
    case idle
    /// Waiting for a usable network path (offline, or Low Data Mode or an
    /// expensive path for a background prefetch).
    case waitingForNetwork
    /// Downloading: bytes on disk so far, of `total`.
    case downloading(received: Int64, total: Int64)
    /// Hashing the downloaded file.
    case verifying
    /// Unpacking and checking code signatures.
    case installing
    /// The pinned pack is installed and verified.
    case installed(ChromiumRuntimeInstallation)
    /// The last attempt failed; another starts after a delay (`attempt` counts from 1).
    case failed(ChromiumRuntimeInstallError, attempt: Int)

    /// Download progress from 0 to 1 while downloading, nil otherwise.
    public var fraction: Double? {
        guard case .downloading(let received, let total) = self, total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }

    /// Stable name for diagnostics (`debug.cef`).
    public var name: String {
        switch self {
        case .idle: "idle"
        case .waitingForNetwork: "waitingForNetwork"
        case .downloading: "downloading"
        case .verifying: "verifying"
        case .installing: "installing"
        case .installed: "installed"
        case .failed: "failed"
        }
    }
}
