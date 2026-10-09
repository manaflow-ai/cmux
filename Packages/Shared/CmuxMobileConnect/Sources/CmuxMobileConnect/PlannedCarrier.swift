public import CmuxLink
import CmuxLinkDirect

/// A carrier that races only while its Mac's plan admits it, and reports
/// direct outcomes back so a reachable-but-silent Mac falls back to the
/// other carriers (b4-direct.md, `directFailed`).
public struct PlannedCarrier: LinkCarrier {
    public let inner: any LinkCarrier
    public let plan: MobileCarrierPlan

    public init(_ inner: any LinkCarrier, plan: MobileCarrierPlan) {
        self.inner = inner
        self.plan = plan
    }

    public var kind: CarrierKind { inner.kind }
    public var candidatePaths: [PathKind] { inner.candidatePaths }

    public func connect(to peer: LinkPeer) async throws -> any LinkTransport {
        guard plan.admits(inner.kind) else { throw MobileConnectError.excludedByPlan(inner.kind) }
        let isDirect = inner.kind == .direct
        do {
            let transport = try await inner.connect(to: peer)
            if isDirect { plan.recordDirect(succeeded: true) }
            return transport
        } catch is CancellationError {
            throw CancellationError()
        } catch DirectCarrierError.routeUnavailable(let blocker) {
            throw DirectCarrierError.routeUnavailable(blocker)
        } catch {
            if isDirect, !Task.isCancelled { plan.recordDirect(succeeded: false) }
            throw error
        }
    }
}
