import Foundation

/// Env-layer cache API for `cmux vm env` (see docs/cloud-env.md).
///
/// A layer maps a chain hash (provider + base image + spec step prefix) to the
/// snapshot taken after that step succeeded. The web backend stores the
/// mapping; this client resolves the deepest cached layer and records new ones.

public struct VMEnvLayer {
    public let provider: String?
    public let chainHash: String
    public let stepIndex: Int
    public let stepName: String?
    public let snapshotID: String
    public let specDigest: String
    public let baseImageID: String
}

public struct VMEnvResolveResult {
    public let provider: String
    public let baseImageID: String
    public let layer: VMEnvLayer?
}

extension VMClient {
    public func envResolveLayers(provider: String? = nil, chainHashes: [String]) async throws -> VMEnvResolveResult {
        var body: [String: Any] = ["chainHashes": chainHashes]
        if let provider { body["provider"] = provider }
        let (data, http) = try await request("POST", path: "/api/vm/env/layers/resolve", jsonBody: body)
        try ensureOK(http, data: data)
        let obj = try decodeJSONObject(data)
        guard let providerValue = obj["provider"] as? String,
              let baseImageID = obj["baseImageId"] as? String, !baseImageID.isEmpty
        else {
            throw VMClientError.malformedResponse("Cloud VM env resolve response was missing required fields.")
        }
        let layer = (obj["layer"] as? [String: Any]).flatMap(Self.decodeEnvLayer)
        return VMEnvResolveResult(provider: providerValue, baseImageID: baseImageID, layer: layer)
    }

    public func envRecordLayer(
        provider: String? = nil,
        baseImageID: String,
        chainHash: String,
        stepIndex: Int,
        stepName: String?,
        specDigest: String,
        snapshotID: String
    ) async throws -> VMEnvLayer {
        var body: [String: Any] = [
            "baseImageId": baseImageID,
            "chainHash": chainHash,
            "stepIndex": stepIndex,
            "specDigest": specDigest,
            "snapshotId": snapshotID,
        ]
        if let provider { body["provider"] = provider }
        if let stepName, !stepName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["stepName"] = stepName
        }
        let (data, http) = try await request("POST", path: "/api/vm/env/layers", jsonBody: body)
        try ensureOK(http, data: data)
        let obj = try decodeJSONObject(data)
        guard let layer = Self.decodeEnvLayer(obj) else {
            throw VMClientError.malformedResponse("Cloud VM env layer response was missing required fields.")
        }
        return layer
    }

    public func envListLayers(provider: String? = nil, specDigest: String? = nil) async throws -> [VMEnvLayer] {
        var query: [URLQueryItem] = []
        if let provider { query.append(URLQueryItem(name: "provider", value: provider)) }
        if let specDigest, !specDigest.isEmpty { query.append(URLQueryItem(name: "specDigest", value: specDigest)) }
        let (data, http) = try await request("GET", path: "/api/vm/env/layers", queryItems: query)
        try ensureOK(http, data: data)
        let obj = try decodeJSONObject(data)
        let rawLayers = obj["layers"] as? [[String: Any]] ?? []
        return rawLayers.compactMap(Self.decodeEnvLayer)
    }

    private static func decodeEnvLayer(_ obj: [String: Any]) -> VMEnvLayer? {
        guard let chainHash = obj["chainHash"] as? String, !chainHash.isEmpty,
              let snapshotID = obj["snapshotId"] as? String, !snapshotID.isEmpty,
              let specDigest = obj["specDigest"] as? String,
              let baseImageID = obj["baseImageId"] as? String
        else { return nil }
        let stepIndex = (obj["stepIndex"] as? Int)
            ?? (obj["stepIndex"] as? NSNumber)?.intValue
            ?? Int((obj["stepIndex"] as? Double) ?? -1)
        guard stepIndex >= 0 else { return nil }
        let stepName = (obj["stepName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let provider = (obj["provider"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return VMEnvLayer(
            provider: provider,
            chainHash: chainHash,
            stepIndex: stepIndex,
            stepName: stepName,
            snapshotID: snapshotID,
            specDigest: specDigest,
            baseImageID: baseImageID
        )
    }
}
