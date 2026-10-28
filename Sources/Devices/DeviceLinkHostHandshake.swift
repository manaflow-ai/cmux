import CMUXMobileCore
import CmuxMobileRPC
import CmuxSurfaceCatalogModel
import Foundation

/// Proves the selected host's identity before subscribing to its device events.
@MainActor
struct DeviceLinkHostHandshake {
    let instance: SurfaceDeviceInstanceID
    let clientID: String
    let topics: Set<String>

    func authenticate(
        _ client: MobileCoreRPCClient,
        deadline: ContinuousClock.Instant
    ) async throws -> AsyncStream<MobileEventEnvelope> {
        let streamID = UUID().uuidString.lowercased()
        // Transport establishment consumes the existing probe budget.
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw MobileShellConnectionError.requestTimedOut }
        let parts = remaining.components
        let timeout = UInt64(parts.seconds) * 1_000_000_000 + UInt64(parts.attoseconds / 1_000_000_000)
        // Identity first. Nothing is subscribed or exposed until the authenticated
        // status reply names the exact device and app instance this row expects.
        let probe = try MobileCoreRPCClient.requestData(method: "mobile.events.probe", params: [
            "client_id": clientID,
            "stream_id": streamID,
        ])
        let (_, status) = try await client.sendRequestAndAuthenticatedHostStatus(
            probe,
            timeoutNanoseconds: timeout,
            hostStatusTimeoutNanoseconds: { timeout }
        )
        try DeviceLinkHostIdentity.verify(statusResponse: status, expected: instance)
        let events = await client.subscribe(to: topics)
        let subscribe = try await client.sendRequest(
            MobileCoreRPCClient.requestData(method: "mobile.events.subscribe", params: [
                "client_id": clientID,
                "stream_id": streamID,
                "topics": Array(topics).sorted(),
            ]),
            timeoutNanoseconds: timeout
        )
        guard let object = try JSONSerialization.jsonObject(with: subscribe) as? [String: Any],
              object["stream_id"] as? String == streamID else {
            throw DeviceLinkError.malformedResponse("mobile.events.subscribe")
        }
        return events
    }
}
