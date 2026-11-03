#if DEBUG || CMUX_BENCH_HOOKS
import AppKit

extension HomeNativeTranscriptView {
    /// Read-only native approval geometry and state for capture automation.
    public func debugApprovalCards() -> [(id: String, text: String, pending: Bool, busy: Bool, ended: Bool, allow: CGRect, deny: CGRect)] {
        transcript.debugApprovalCards()
    }
}
#endif
