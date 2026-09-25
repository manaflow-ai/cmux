import CmuxIrxTransport
import Foundation

/// The control-plane rules this Mac's Devices runtime depends on.
///
/// The Devices service names the rules it applied in every directory it
/// issues (`V2Directory.rules`). A directory that lacks a required rule proves
/// the deployed service predates it, so the link says so instead of dialing
/// into a refusal (https://github.com/manaflow-ai/cmux/issues/13458).
struct DeviceLinkControlPlaneRules: Equatable, Sendable {
    /// Same-account Macs with `cmux.mac-devices.v1` may enter a host that
    /// opted in with `cmux.mac-host.v1` (same app namespace and build tag).
    static let macPeerInbound = "cmux.mac-peer-inbound.v1"

    /// What the shipping Mac-to-Mac link requires.
    static let current = DeviceLinkControlPlaneRules(required: [macPeerInbound])

    let required: Set<String>

    /// Whether `directory` proves that Mac-to-Mac admission is implemented.
    ///
    /// Current Workers name the rule explicitly. The previous v2 Worker did
    /// not have `directory.rules`, but its non-optional `inboundPeers` field
    /// was produced by the same exact-account, same-app-namespace and
    /// same-build admission query. Keep that deployed Worker compatible while
    /// still rejecting a response that carries neither proof.
    func isSatisfied(by directory: V2Directory) -> Bool {
        if required.isSubset(of: Set(directory.rules ?? [])) {
            return true
        }
        return directory.rules == nil && directory.inboundPeers != nil
    }
}
