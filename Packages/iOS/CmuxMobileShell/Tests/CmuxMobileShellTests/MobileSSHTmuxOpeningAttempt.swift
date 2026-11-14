@testable import CmuxMobileShell

/// A suspended open request observed by the deterministic opening tests.
@MainActor
struct MobileSSHTmuxOpeningAttempt {
    let session: String
    let completion: CheckedContinuation<MobileSSHTmuxControlClient, any Error>
}
