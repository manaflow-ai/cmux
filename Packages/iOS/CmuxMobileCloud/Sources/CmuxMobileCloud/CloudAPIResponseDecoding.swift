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
        try catalog(from: data).machines
    }

    /// `GET /api/vm` including the server-authoritative create capabilities.
    public func catalog(from data: Data) throws -> CloudMachineCatalog {
        let object = try jsonObject(data)
        guard let items = object["vms"] as? [[String: Any]] else {
            throw CloudAPIError.malformedResponse("missing `vms` array")
        }
        var seenIDs = Set<String>()
        let machines = try items.enumerated().map { index, dict in
            guard let id = dict["id"] as? String, !id.isEmpty,
                  let provider = dict["provider"] as? String, !provider.isEmpty else {
                throw CloudAPIError.malformedResponse("machine \(index) is missing id or provider")
            }
            guard seenIDs.insert(id).inserted else {
                throw CloudAPIError.malformedResponse("machine \(index) duplicates id \(id)")
            }
            let rawStatus = (dict["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = rawStatus.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            let displayName = (dict["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let slug = (dict["slug"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return CloudMachine(
                id: id,
                provider: provider,
                status: status,
                displayName: displayName,
                slug: slug,
                resources: Self.resources(dict["resources"])
            )
        }
        let availableKinds: Set<CloudMachineKind>?
        let machineLimits: CloudMachineLimits?
        if let limits = object["limits"] as? [String: Any] {
            if let entries = limits["imageKinds"] as? [[String: Any]] {
                availableKinds = Set(entries.compactMap { entry in
                    guard let raw = entry["kind"] as? String else { return nil }
                    return CloudMachineKind(rawValue: raw)
                })
            } else {
                availableKinds = nil
            }
            machineLimits = CloudMachineLimits(
                maxActiveMachines: Self.int(limits["maxActiveVms"]),
                activeMachineCount: Self.int(limits["activeVmCount"]),
                planID: limits["planId"] as? String,
                canCreateMachines: limits["canCreateMachines"] as? Bool,
                createAccessReason: (limits["createAccessReason"] as? String).flatMap {
                    CloudMachineCreationAccess(serverValue: $0)
                },
                createUpgradePlanID: limits["createUpgradePlanId"] as? String,
                memoryOptionsMb: Self.intArray(limits["memoryOptionsMb"]),
                lockedMemoryOptionsMb: Self.optionalIntArray(limits["lockedMemoryOptionsMb"]),
                memoryUpgradePlanID: limits["memoryUpgradePlanId"] as? String,
                memoryUpgradePlansByMb: limits["memoryUpgradePlansByMb"] as? [String: String],
                resourcePool: Self.resourcePool(limits)
            )
        } else {
            availableKinds = nil
            machineLimits = nil
        }
        return CloudMachineCatalog(
            machines: machines,
            availableKinds: availableKinds,
            limits: machineLimits
        )
    }

    /// `POST /api/vm` → the newly created machine.
    public func createdMachine(from data: Data) throws -> CloudMachine {
        let object = try jsonObject(data)
        return try machine(from: object, context: "create response")
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
        // Only an explicit server opt-in enables private-tunnel trust. A
        // missing invitation alone must never weaken authentication.
        guard let trust = try? JSONDecoder().decode(AttachTrust.self, from: data) else {
            throw CloudAPIError.malformedResponse("attach trustedCarrier must be a boolean")
        }
        let trustedCarrier = trust.trustedCarrier == true
        return CloudAttachEndpoint(route: route, session: session, invitation: invitation, trustedCarrier: trustedCarrier)
    }

    private struct AttachTrust: Decodable {
        let trustedCarrier: Bool?
    }

    /// `POST .../cmux-remote/approve` → whether the claim is approved.
    public func approvalGranted(from data: Data) throws -> Bool {
        let object = try jsonObject(data)
        return (object["approved"] as? Bool) ?? false
    }

    /// The server's safe error copy from an error body, if any.
    public func errorEnvelope(from data: Data) -> (message: String?, action: String?) {
        guard let object = try? jsonObject(data) else { return (nil, nil) }
        return (
            (object["message"] as? String) ?? (object["error"] as? String),
            object["action"] as? String
        )
    }

    /// The server's `message` or `error` field from an error body, if any.
    public func errorMessage(from data: Data) -> String? {
        errorEnvelope(from: data).message
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudAPIError.malformedResponse("response is not a JSON object")
        }
        return object
    }

    private func machine(from dict: [String: Any], context: String) throws -> CloudMachine {
        guard let id = dict["id"] as? String, !id.isEmpty,
              let provider = dict["provider"] as? String, !provider.isEmpty else {
            throw CloudAPIError.malformedResponse("machine is missing id or provider in \(context)")
        }
        let rawStatus = (dict["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = rawStatus.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        let displayName = (dict["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let slug = (dict["slug"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return CloudMachine(id: id, provider: provider, status: status, displayName: displayName, slug: slug)
    }

    private static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    /// `vms[].resources: {vcpus, memoryMb}`; nil unless both are positive.
    private static func resources(_ value: Any?) -> CloudMachineResources? {
        guard let object = value as? [String: Any],
              let vcpus = int(object["vcpus"]), vcpus > 0,
              let memoryMb = int(object["memoryMb"]), memoryMb > 0 else { return nil }
        return CloudMachineResources(vcpus: vcpus, memoryMb: memoryMb)
    }

    /// The `limits` pool fields; nil unless the plan has a positive pool.
    /// Missing usage reads as nothing in use.
    private static func resourcePool(_ limits: [String: Any]) -> CloudResourcePool? {
        guard let poolVcpus = int(limits["poolVcpus"]), poolVcpus > 0,
              let poolMemoryMb = int(limits["poolMemoryMb"]), poolMemoryMb > 0 else { return nil }
        return CloudResourcePool(
            poolVcpus: poolVcpus,
            poolMemoryMb: poolMemoryMb,
            usedVcpus: max(0, int(limits["usedVcpus"]) ?? 0),
            usedMemoryMb: max(0, int(limits["usedMemoryMb"]) ?? 0)
        )
    }

    private static func intArray(_ value: Any?) -> [Int] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap(int).filter { $0 > 0 }
    }

    private static func optionalIntArray(_ value: Any?) -> [Int]? {
        guard let value, !(value is NSNull) else { return nil }
        return intArray(value)
    }
}
