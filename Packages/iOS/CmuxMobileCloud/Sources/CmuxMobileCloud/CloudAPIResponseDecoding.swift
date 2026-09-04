public import Foundation

/// Decodes `/api/vm` response bodies into the domain values.
///
/// Mirrors the Mac's `VMClient` decoders field for field, tolerating the
/// numeric shapes `JSONSerialization` produces.
public struct CloudAPIResponseDecoding: Sendable {
    /// Creates a decoder.
    public init() {}

    /// `GET /api/vm` → the `vms` array.
    public func machines(from data: Data) throws -> [CloudMachine] {
        let object = try jsonObject(data)
        guard let items = object["vms"] as? [[String: Any]] else {
            throw CloudAPIError.malformedResponse("missing `vms` array")
        }
        return try items.enumerated().map { index, dict in
            guard let id = dict["id"] as? String, !id.isEmpty,
                  let provider = dict["provider"] as? String, !provider.isEmpty else {
                throw CloudAPIError.malformedResponse("machine \(index) is missing id or provider")
            }
            let rawStatus = (dict["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = rawStatus.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            let displayName = (dict["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return CloudMachine(id: id, provider: provider, status: status, displayName: displayName)
        }
    }

    /// `POST /api/vm/tunnel` → the enrollment.
    public func tunnelEnrollment(from data: Data) throws -> CloudTunnelEnrollment {
        let object = try jsonObject(data)
        guard let tunnelId = object["tunnelId"] as? String,
              let provider = object["provider"] as? String,
              let deviceFingerprint = object["deviceFingerprint"] as? String,
              let clientConfig = object["clientConfig"] as? String,
              let serverPublicKey = object["serverPublicKey"] as? String,
              let endpointPort = Self.int(object["endpointPort"]) else {
            throw CloudAPIError.malformedResponse("tunnel response is missing required fields")
        }
        let address = object["address"] as? [String: Any]
        return CloudTunnelEnrollment(
            tunnelId: tunnelId,
            provider: provider,
            deviceFingerprint: deviceFingerprint,
            clientConfig: clientConfig,
            serverPublicKey: serverPublicKey,
            endpointHost: object["endpointHost"] as? String,
            endpointPort: endpointPort,
            routes: (object["routes"] as? [String]) ?? [],
            addressV4: address?["ipv4"] as? String,
            addressV6: address?["ipv6"] as? String,
            created: (object["created"] as? Bool) ?? false,
            rotated: (object["rotated"] as? Bool) ?? false
        )
    }

    /// `POST /api/vm/<id>/attach-endpoint` → the route and optional invitation.
    public func attachEndpoint(from data: Data) throws -> CloudAttachEndpoint {
        let object = try jsonObject(data)
        guard (object["transport"] as? String) == "cmux-remote",
              let route = object["route"] as? String, !route.isEmpty,
              let session = object["session"] as? String else {
            throw CloudAPIError.malformedResponse("attach response is missing required fields")
        }
        var invitation: CloudAttachEndpoint.Invitation?
        if let raw = object["invitation"] as? [String: Any],
           let uri = raw["uri"] as? String, !uri.isEmpty,
           let invitationId = raw["invitationId"] as? String, !invitationId.isEmpty {
            invitation = .init(uri: uri, invitationId: invitationId)
        }
        return CloudAttachEndpoint(route: route, session: session, invitation: invitation)
    }

    /// `POST .../cmux-remote/approve` → whether the claim is approved.
    public func approvalGranted(from data: Data) throws -> Bool {
        let object = try jsonObject(data)
        return (object["approved"] as? Bool) ?? false
    }

    /// The server's `message` or `error` field from an error body, if any.
    public func errorMessage(from data: Data) -> String? {
        guard let object = try? jsonObject(data) else { return nil }
        return (object["message"] as? String) ?? (object["error"] as? String)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudAPIError.malformedResponse("response is not a JSON object")
        }
        return object
    }

    private static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}
