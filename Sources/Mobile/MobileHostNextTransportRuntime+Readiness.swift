#if DEBUG
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxNextTransport
import Foundation
import IrohLib
import Observation
import OSLog

extension MobileHostNextTransportRuntime {
    // MARK: - Readiness (ratchets upward; stale generations are inert)

    func setReadiness(_ new: NextTransportReadiness, generation gen: UInt64) {
        guard generation == gen else {
            MobileHostNextTransportRuntime.logger.notice(
                "readiness advance to \(new.description, privacy: .public) dropped: stale generation")
            return
        }
        guard readiness < new else { return }
        readiness = new
        refreshStateDescription()
        MobileHostNextTransportRuntime.logger.notice(
            """
            host readiness -> \(new.description, privacy: .public) \
            state=\(self.state, privacy: .public)
            """)
    }

    /// `.published` is the ONLY place the presence route (and therefore the
    /// ticket) becomes visible; it requires `.relayAttached` first.
    func publishIfReady(generation gen: UInt64) {
        guard generation == gen else { return }
        guard readiness >= .relayAttached else { return }
        setReadiness(.published, generation: gen)
        publishPresenceRoute()
    }

    /// Dev diagnostic (not product copy; the Debug menu renders it raw).
    func refreshStateDescription() {
        switch readiness {
        case .starting:
            state = "starting"
        case .bound:
            state = relayURL == nil ? "bound (awaiting relay credential)" : "bound"
        case .relayAttached:
            state = relayURL == nil ? "relay-attached (direct only)" : "relay-attached"
        case .published:
            state = relayURL == nil ? "ready (direct only)" : "ready (relay)"
        }
    }

    /// Graduation slice 3: advertise the parallel host through the existing
    /// presence `routes` field. The route is identity + relay only (private
    /// addresses never enter presence), rides the same status pipeline as the
    /// iroh route so heartbeats pick it up automatically, and is facade-only:
    /// old clients drop the unknown kind at their failable-decode boundaries
    /// and no legacy selection/dial path treats it as a candidate. Reached
    /// only from generation-checked `.published` transitions (and relay-URL
    /// rotations at `.published`), so a stale start can never publish.
    func publishPresenceRoute() {
        guard let endpointID else {
            MobileHostNextTransportRuntime.logger.notice(
                "presence route publish skipped: no endpoint id")
            return
        }
        do {
            let route = try CmxAttachRoute(
                id: CmxAttachTransportKind.nextTransport.rawValue,
                kind: .nextTransport,
                endpoint: .peer(
                    id: endpointID,
                    relayHint: nil,
                    directAddrs: [],
                    relayURL: relayURL
                ),
                priority: 30
            )
            MobileHostService.shared.updateNextTransportRoute(route)
            MobileHostNextTransportRuntime.logger.notice(
                """
                presence route PUBLISHED endpoint=\(String(endpointID.prefix(8)), privacy: .public) \
                relay=\(self.relayURL ?? "none", privacy: .public) priority=30
                """)
        } catch {
            MobileHostNextTransportRuntime.logger.error(
                "next-transport presence route rejected: \(String(describing: error))")
        }
    }

}
#endif
