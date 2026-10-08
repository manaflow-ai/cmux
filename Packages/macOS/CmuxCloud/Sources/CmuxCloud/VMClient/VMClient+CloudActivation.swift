import CmuxAuthRuntime
import Foundation

extension VMClient {
    public func listPage(
        allowWhenCloudDisabled: Bool = false,
        expectedTeamScope: AuthenticatedTeamScope? = nil
    ) async throws -> VMListPage {
        let (retentionToken, listIdentity, listTeamID) = await MainActor.run { [auth, resourceStats] in
            (resourceStats.beginRetention(), auth.authenticatedSessionIdentity, auth.resolvedTeamID)
        }
        return try await withOperation(.list, foreground: false) {
            let (data, http) = try await request(
                "GET", path: "/api/vm", timeoutSeconds: 15,
                allowWhenCloudDisabled: allowWhenCloudDisabled,
                expectedTeamScope: expectedTeamScope
            )
            try ensureOK(http, data: data)
            let obj = try decodeJSONObject(data)
            guard let items = obj["vms"] as? [[String: Any]] else {
                throw VMClientError.malformedResponse("missing `vms` array")
            }
            var limits: VMPlanLimits?
            if let rawLimits = obj["limits"] as? [String: Any],
               let planId = rawLimits["planId"] as? String {
                // Absent or null means the plan has no active-machine cap.
                let maxActiveVms = (rawLimits["maxActiveVms"] as? Int) ?? (rawLimits["maxActiveVms"] as? NSNumber)?.intValue
                let freeAccessWindowDays = (rawLimits["freeAccessWindowDays"] as? Int)
                    ?? (rawLimits["freeAccessWindowDays"] as? NSNumber)?.intValue
                    ?? 0
                limits = VMPlanLimits(
                    maxActiveVms: maxActiveVms,
                    planId: planId,
                    freeAccessWindowDays: freeAccessWindowDays,
                    freeAccessExpiresAt: Self.epochMilliseconds(rawLimits["freeAccessExpiresAt"]),
                    memoryOptionsMb: Self.decodeIntArray(rawLimits["memoryOptionsMb"]),
                    maxDiskMb: Self.decodePositiveInt(rawLimits["maxDiskMb"]),
                    maxMemoryMb: Self.decodePositiveInt(rawLimits["maxMemoryMb"]),
                    maxVcpus: Self.decodePositiveInt(rawLimits["maxVcpus"]),
                    lockedMemoryOptionsMb: (rawLimits["lockedMemoryOptionsMb"] as? [Any]).map { Self.decodeIntArray($0) },
                    memoryUpgradePlanId: (rawLimits["memoryUpgradePlanId"] as? String)
                        .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 },
                    memoryUpgradePlansByMb: rawLimits["memoryUpgradePlansByMb"] as? [String: String],
                    vcpusByMemoryMb: Self.decodePositiveIntMap(rawLimits["vcpusByMemoryMb"]),
                    activeVmCount: rawLimits["activeVmCount"] as? Int,
                    imageKinds: Self.decodeImageKinds(rawLimits["imageKinds"]),
                    resourcePool: CloudVMResourcePool(limits: rawLimits)
                )
            }
            let vms = try items.enumerated().map { index, dict -> VMSummary in
                guard let id = dict["id"] as? String, !id.isEmpty else {
                    throw VMClientError.malformedResponse("Cloud VM list response was missing required fields for item \(index).")
                }
                guard let provider = dict["provider"] as? String, !provider.isEmpty else {
                    throw VMClientError.malformedResponse("Cloud VM list response was missing required fields for item \(index).")
                }
                guard let image = dict["image"] as? String, !image.isEmpty else {
                    throw VMClientError.malformedResponse("Cloud VM list response was missing required fields for item \(index).")
                }
                let rawStatus = (dict["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayStatus = rawStatus.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
                let createdAt = (dict["createdAt"] as? Int64)
                    ?? Int64((dict["createdAt"] as? Double) ?? 0)
                var summary = VMSummary(id: id, provider: provider, status: displayStatus, image: image, createdAt: createdAt, base: decodeBaseSummary(dict["base"]))
                summary.kind = Self.decodeKind(dict["kind"])
                summary.capabilities = VMCapabilities(vmResponse: dict)
                if let label = dict["displayName"] as? String, !label.isEmpty {
                    summary.displayName = label
                }
                summary.slug = (dict["slug"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                summary.createdBy = VMCreator(vmResponse: dict)
                summary.agentUpdates = CloudAgentUpdates(wireValue: dict["agentUpdates"])
                summary.resourceReservation = Self.decodeResourceReservation(dict["resources"])
                summary.freeAccessExpiresAt = Self.epochMilliseconds(dict["freeAccessExpiresAt"])
                if let address = dict["address"] as? [String: Any] {
                    summary.addressIPv4 = (address["ipv4"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    summary.addressIPv6 = (address["ipv6"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                }
                summary.cmuxTuiContract = (dict["cmuxTuiContract"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return summary
            }
            machineCache.record(hasAnyMachine: !vms.isEmpty)
            // Background discovery also reads resource stats. Register its
            // complete fleet before returning, but only when the auth account
            // and team are still the ones that produced this response. The
            // store token fences reset and out-of-order list responses.
            let machineIDs = Set(vms.map(\.id))
            await MainActor.run { [auth, resourceStats] in
                guard !Task.isCancelled, let listIdentity,
                      auth.authenticatedSessionIdentity == listIdentity,
                      auth.resolvedTeamID == listTeamID else { return }
                resourceStats.retain(machineIDs: machineIDs, token: retentionToken)
            }
            return VMListPage(vms: vms, limits: limits)
        }
    }

    /// Enroll (or refresh) this Mac's WireGuard tunnel into the user's private
    /// Cloud VM network. Idempotent per device: safe to call on every launch.
    /// The server never sees a private key — only `clientPublicKey` travels.
    func enrollTunnel(
        clientPublicKey: String,
        deviceID: String,
        deviceFingerprint: String,
        tunnelPurpose: String,
        deviceName: String? = nil,
        modelIdentifier: String? = nil,
        osVersion: String? = nil,
        architecture: String? = nil,
        cmuxVersion: String? = nil,
        cmuxBuild: String? = nil,
        cmuxChannel: String? = nil,
        allowWhenCloudDisabled: Bool = false,
        expectedTeamScope: AuthenticatedTeamScope? = nil
    ) async throws -> VMTunnelEndpoint {
        return try await withOperation(.tunnel, foreground: true) {
            var body: [String: Any] = [
                "clientPublicKey": clientPublicKey,
                "deviceId": deviceID,
                "deviceFingerprint": deviceFingerprint,
                "tunnelPurpose": tunnelPurpose,
            ]
            if let deviceName, !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                body["deviceName"] = deviceName
            }
            for (key, value) in [
                ("modelIdentifier", modelIdentifier),
                ("osVersion", osVersion),
                ("architecture", architecture),
                ("cmuxVersion", cmuxVersion),
                ("cmuxBuild", cmuxBuild),
                ("cmuxChannel", cmuxChannel),
            ] where value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                body[key] = value
            }
            let (data, http) = try await request(
                "POST", path: "/api/vm/tunnel", jsonBody: body,
                allowWhenCloudDisabled: allowWhenCloudDisabled,
                expectedTeamScope: expectedTeamScope
            )
            try ensureOK(http, data: data)
            return try Self.decodeTunnelEndpoint(
                decodeJSONObject(data),
                fallbackPurpose: tunnelPurpose
            )
        }
    }


}
