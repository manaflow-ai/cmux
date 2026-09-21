import Foundation

/// The `attach` block a create response carries when the machine already has a
/// private address: everything the first link needs, so the app can dial the
/// daemon straight from `POST /api/vm` instead of asking the attach endpoint.
/// `readiness` is always `"dial"` today: the Noise handshake is the readiness proof.
struct VMCreateAttach: Equatable, Sendable {
    let route: String
    let session: String
    /// The daemon serves the trusted-carrier listener: dial `--carrier`, no enrollment.
    let trustedCarrier: Bool
    let daemonBuild: VMCmuxRemoteEndpoint.DaemonBuild?
    /// The image bakes the guest tools; informational for the app.
    let guestToolsBaked: Bool
    let readiness: String
    /// When this process received the block; the CLI answers from it only while fresh.
    let receivedAt: Date
}

/// What `POST /api/vm` returned: the machine, plus the attach block when the
/// control plane could name the route (feature-detected; older backends omit it).
struct VMCreateResult {
    let summary: VMSummary
    let attach: VMCreateAttach?
}

extension VMClient {
    /// Parses one create response. Addresses decode like `status(id:)`; the attach
    /// block is accepted only for the cmux-remote transport with a dialable route.
    nonisolated static func decodeCreateResult(_ obj: [String: Any], now: Date) throws -> VMCreateResult {
        guard let id = obj["id"] as? String,
              let providerValue = obj["provider"] as? String,
              let imageValue = obj["image"] as? String
        else {
            throw VMClientError.malformedResponse("Cloud VM create response was missing required fields.")
        }
        // Preserve the server timestamp on idempotent replays and under local clock skew.
        // Fall back to the local clock only for older servers that omit it.
        let serverCreatedAt = (obj["createdAt"] as? Int64)
            ?? Int64((obj["createdAt"] as? Double) ?? 0)
        let createdAt = serverCreatedAt > 0 ? serverCreatedAt : Int64(now.timeIntervalSince1970 * 1000)
        let rawStatus = (obj["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayStatus = rawStatus.flatMap { $0.isEmpty ? nil : $0 } ?? "running"
        var summary = VMSummary(id: id, provider: providerValue, status: displayStatus, image: imageValue, createdAt: createdAt, base: nil)
        summary.kind = decodeKind(obj["kind"])
        summary.capabilities = VMCapabilities(vmResponse: obj)
        summary.displayName = (obj["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        summary.slug = (obj["slug"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let address = obj["address"] as? [String: Any] {
            summary.addressIPv4 = (address["ipv4"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            summary.addressIPv6 = (address["ipv6"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return VMCreateResult(summary: summary, attach: decodeCreateAttach(obj["attach"], receivedAt: now))
    }

    nonisolated static func decodeCreateAttach(_ raw: Any?, receivedAt: Date) -> VMCreateAttach? {
        guard let obj = raw as? [String: Any],
              (obj["transport"] as? String) == "cmux-remote",
              let route = (obj["route"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !route.isEmpty,
              IPNetworkPrefix.routeHost(route) != nil else { return nil }
        var daemonBuild: VMCmuxRemoteEndpoint.DaemonBuild?
        if let build = obj["daemonBuild"] as? [String: Any] {
            daemonBuild = .init(
                commit: build["commit"] as? String,
                remoteProtocol: (build["remoteProtocol"] as? Int) ?? (build["remoteProtocol"] as? Double).map(Int.init),
                version: build["version"] as? String
            )
        }
        let session = (obj["session"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "cloud"
        return VMCreateAttach(
            route: route,
            session: session,
            trustedCarrier: (obj["trustedCarrier"] as? Bool) ?? false,
            daemonBuild: daemonBuild,
            guestToolsBaked: (obj["guestToolsBaked"] as? Bool) ?? false,
            readiness: (obj["readiness"] as? String) ?? "dial",
            receivedAt: receivedAt
        )
    }

    /// `POST /api/vm`. `image` is the explicit override (`vm new --image`) and wins
    /// server-side. The caller owns key stability across retries; VMClient only
    /// forwards the key so the backend can short-circuit duplicate paid creates.
    func createMachine(
        image: String? = nil,
        kind: VMMachineKind? = nil,
        provider: String? = nil,
        persistentHome: Bool = false,
        perMachineHome: Bool = false,
        memoryMb: Int? = nil,
        displayName: String? = nil,
        idempotencyKey: String
    ) async throws -> VMCreateResult {
        return try await withOperation(.create, foreground: true) {
            var body: [String: Any] = [:]
            if let image { body["image"] = image }
            if let kind { body["kind"] = kind.rawValue }
            if let provider { body["provider"] = provider }
            if persistentHome { body["persistentHome"] = true }
            if perMachineHome { body["perMachineHome"] = true }
            if let memoryMb { body["memoryMb"] = memoryMb }
            if let displayName { body["displayName"] = displayName }
            let (data, http) = try await request(
                "POST",
                path: "/api/vm",
                jsonBody: body,
                extraHeaders: ["Idempotency-Key": idempotencyKey],
                timeoutSeconds: Self.createTimeoutSeconds
            )
            try ensureOK(http, data: data)
            let result = try Self.decodeCreateResult(decodeJSONObject(data), now: Date())
            machineCache.record(hasAnyMachine: true)
            return result
        }
    }

    /// The summary-only form for callers that do not dial (the socket's `vm.create`
    /// payload, tests).
    func create(
        image: String? = nil,
        kind: VMMachineKind? = nil,
        provider: String? = nil,
        persistentHome: Bool = false,
        perMachineHome: Bool = false,
        memoryMb: Int? = nil,
        displayName: String? = nil,
        idempotencyKey: String
    ) async throws -> VMSummary {
        try await createMachine(
            image: image, kind: kind, provider: provider, persistentHome: persistentHome,
            perMachineHome: perMachineHome, memoryMb: memoryMb, displayName: displayName,
            idempotencyKey: idempotencyKey
        ).summary
    }

    /// Resolves the session tokens once so the create that follows a sheet's Create
    /// does not pay for a refresh on the click path. Failures are the create's to report.
    func prewarmAuth() async {
        _ = try? await auth.currentTokens()
    }
}
