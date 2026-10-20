#if os(iOS)
import Foundation

/// An optional inline link shown under a gate's guidance body in
/// ``SetupHelpView``.
struct SetupHelpGateLink {
    let title: String
    let url: URL
}
#endif
