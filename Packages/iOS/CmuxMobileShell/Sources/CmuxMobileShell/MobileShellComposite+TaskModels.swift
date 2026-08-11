internal import CmuxMobileRPC
public import CmuxMobileShellModel
import Foundation

private enum MobileTaskModelRefreshEvent: Sendable {
    case host(MobileTaskModelListResult?)
    case backend([MobileTaskAgentModel]?)
}

extension MobileShellComposite {
    /// Resolves a secondary control subscription for a physical Mac: the
    /// exact pairing when a tag is given, otherwise any same-device pairing.
    /// Mirrors the pre-MacPairingKey device-id lookup these capability
    /// checks were written against.
    func controlSubscriptionMatching(
        macDeviceID: String,
        instanceTag: String?
    ) -> SecondaryMacSubscription? {
        let probe = MacPairingKey(macDeviceID: macDeviceID, instanceTag: instanceTag)
        if probe.normalizedInstanceTag != nil,
           let exact = secondaryMacSubscriptions[probe] {
            return exact
        }
        for key in secondaryMacSubscriptions.keys
        where key.canonicalMacDeviceID == probe.canonicalMacDeviceID {
            guard let subscription = secondaryMacSubscriptions[key] else { continue }
            if instanceTag == nil
                || key.normalizedInstanceTag == probe.normalizedInstanceTag
                || subscription.authenticatedInstanceTag == instanceTag
                || subscription.storedInstanceTag == instanceTag {
                return subscription
            }
        }
        return nil
    }

    /// Whether the selected Mac instance advertises task model discovery.
    ///
    /// - Parameters:
    ///   - macDeviceID: Physical Mac selected in the task composer.
    ///   - instanceTag: Exact paired app instance, when known.
    /// - Returns: `true` only for a matching host capability announcement.
    public func supportsTaskModels(
        macDeviceID: String,
        instanceTag: String?
    ) -> Bool {
        if matchesForegroundPairing(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ) {
            return supportedHostCapabilities.contains(Self.taskModelsCapability)
        }
        if let subscription = controlSubscriptionMatching(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ) {
            return subscription.supportedHostCapabilities.contains(
                Self.taskModelsCapability
            )
        }
        let aliases = pairedMacAliasIDs(
            for: macDeviceID,
            instanceTag: instanceTag
        )
        if let instanceTag {
            return aliases.contains {
                presenceMap.instance(deviceId: $0, tag: instanceTag)?
                    .capabilities.contains(Self.taskModelsCapability) == true
            }
        }
        return aliases.contains {
            presenceMap.soleRouteAdvertisingInstance(deviceId: $0)?
                .capabilities.contains(Self.taskModelsCapability) == true
        }
    }

    /// Fetches one provider's models from the selected Mac.
    ///
    /// This deliberately probes the read-only RPC even when the cached
    /// capability announcement is stale. Older hosts reject the unknown method,
    /// which lets the caller fall back to the backend catalog without hiding
    /// models that a newer installed agent can discover authoritatively.
    ///
    /// - Parameters:
    ///   - provider: Coding-agent provider to query.
    ///   - macDeviceID: Physical Mac selected in the task composer.
    ///   - instanceTag: Exact paired app instance, when known.
    /// - Returns: Models plus their discovery source.
    /// - Throws: A connection or response error when discovery cannot complete.
    public func fetchTaskModels(
        provider: MobileTaskAgentProvider,
        macDeviceID: String,
        instanceTag: String?
    ) async throws -> MobileTaskModelListResult {
        if !matchesForegroundPairing(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ) || remoteClient == nil {
            guard await switchToMac(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            ) else {
                throw MobileShellConnectionError.connectionClosed
            }
        }
        let context = captureWorkspaceCreateContext()
        guard !Task.isCancelled,
              let context,
              context.macDeviceID == macDeviceID,
              instanceTag == nil || context.instanceTag == instanceTag else {
            throw MobileShellConnectionError.invalidResponse
        }

        do {
            let response = try await context.client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "mobile.task.models.list",
                    params: ["provider": provider.rawValue]
                ),
                // Claude's installed-agent control request is intentionally
                // bounded at 30 seconds on the Mac. Leave transport headroom;
                // the concurrent backend catalog keeps the picker responsive.
                timeoutNanoseconds: 35_000_000_000
            )
            guard context.isCurrent(
                macDeviceID: foregroundMacDeviceID,
                instanceTag: activeMacInstanceTag,
                client: remoteClient,
                generation: connectionGeneration
            ), isSignedIn,
                  let object = try JSONSerialization.jsonObject(with: response)
                    as? [String: Any],
                  let rawSource = object["source"] as? String,
                  let source = MobileTaskModelListSource(rawValue: rawSource),
                  let rawModels = object["models"] as? [[String: Any]]
            else {
                throw MobileShellConnectionError.invalidResponse
            }
            var models: [MobileTaskAgentModel] = []
            models.reserveCapacity(rawModels.count)
            var seenIDs: Set<String> = []
            for rawModel in rawModels {
                guard let id = rawModel["id"] as? String,
                      !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let displayName = rawModel["display_name"] as? String,
                      !displayName.isEmpty,
                      seenIDs.insert(id).inserted else {
                    throw MobileShellConnectionError.invalidResponse
                }
                models.append(MobileTaskAgentModel(
                    id: id,
                    displayName: displayName
                ))
            }
            return MobileTaskModelListResult(models: models, source: source)
        } catch {
            // View lifecycle and connection-trigger retries intentionally
            // cancel superseded probes. Cancellation says nothing about Mac
            // availability and must never enter transport recovery.
            guard !Task.isCancelled else { throw error }
            if context.isCurrent(
                macDeviceID: foregroundMacDeviceID,
                instanceTag: activeMacInstanceTag,
                client: remoteClient,
                generation: connectionGeneration
            ) {
                handleMacAvailabilityFailureIfCurrent(
                    after: error,
                    expectedClient: context.client,
                    expectedGeneration: context.generation
                )
            }
            throw error
        }
    }

    /// Returns cached models synchronously for composer rendering and restore.
    ///
    /// - Parameters:
    ///   - provider: Coding-agent provider to resolve.
    ///   - macDeviceID: Physical Mac selected in the task composer.
    ///   - instanceTag: Exact paired instance; the cache intentionally remains
    ///     device/provider scoped so app rebuilds on one Mac share discovery.
    /// - Returns: Previously fetched models, or `nil`.
    public func discoveredTaskModels(
        provider: MobileTaskAgentProvider,
        macDeviceID: String,
        instanceTag _: String?
    ) -> [MobileTaskAgentModel]? {
        taskModelCache[
            MobileTaskModelCacheKey(
                macDeviceID: macDeviceID,
                provider: provider
            )
        ]?.result.models
    }

    /// Refreshes one provider from the selected Mac and the over-the-air
    /// catalog concurrently. A backend result can populate a cold picker while
    /// slower installed-agent discovery continues; a nonempty discovered host
    /// result always replaces it.
    ///
    /// Failed refreshes leave an earlier valid cache entry intact.
    ///
    /// - Parameters:
    ///   - provider: Coding-agent provider to query.
    ///   - macDeviceID: Physical Mac selected in the task composer.
    ///   - instanceTag: Exact paired app instance, when known.
    ///   - didUpdate: Main-actor delivery for each result that becomes visible.
    public func refreshTaskModels(
        provider: MobileTaskAgentProvider,
        macDeviceID: String,
        instanceTag: String?,
        didUpdate: (@MainActor (MobileTaskModelListResult) -> Void)? = nil
    ) async {
        await refreshTaskModels(
            provider: provider,
            macDeviceID: macDeviceID,
            hostResultLoader: { [weak self] in
                guard let self else { return nil }
                return try? await self.fetchTaskModels(
                    provider: provider,
                    macDeviceID: macDeviceID,
                    instanceTag: instanceTag
                )
            },
            didUpdate: didUpdate
        )
    }

    private func refreshTaskModels(
        provider: MobileTaskAgentProvider,
        macDeviceID: String,
        hostResultLoader: @escaping @Sendable () async -> MobileTaskModelListResult?,
        didUpdate: (@MainActor (MobileTaskModelListResult) -> Void)? = nil
    ) async {
        let key = MobileTaskModelCacheKey(
            macDeviceID: macDeviceID,
            provider: provider
        )
        let catalogClient = taskModelCatalogClient
        await withTaskGroup(of: MobileTaskModelRefreshEvent.self) { group in
            group.addTask {
                .host(await hostResultLoader())
            }
            group.addTask {
                .backend(try? await catalogClient.models(for: provider))
            }

            for await event in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                switch event {
                case .host(let result):
                    guard let result,
                          result.source == .discovered,
                          !result.models.isEmpty else {
                        continue
                    }
                    cacheTaskModels(result, for: key)
                    didUpdate?(result)
                    group.cancelAll()
                    return
                case .backend(let models):
                    guard let models,
                          !models.isEmpty,
                          taskModelCache[key]?.result.source != .discovered else {
                        continue
                    }
                    let result = MobileTaskModelListResult(
                        models: models,
                        source: .backend
                    )
                    cacheTaskModels(result, for: key)
                    didUpdate?(result)
                }
            }
        }
    }

    /// Applies the source-priority policy through an injectable host result.
    /// Kept internal so package tests can prove that authoritative agent data
    /// performs zero backend requests and legacy host fallbacks do not leak in.
    func refreshTaskModels(
        provider: MobileTaskAgentProvider,
        macDeviceID: String,
        hostResult: MobileTaskModelListResult?
    ) async {
        let key = MobileTaskModelCacheKey(
            macDeviceID: macDeviceID,
            provider: provider
        )
        if let hostResult,
           hostResult.source == .discovered,
           !hostResult.models.isEmpty {
            guard !Task.isCancelled else { return }
            cacheTaskModels(hostResult, for: key)
            return
        }

        guard !Task.isCancelled,
              let models = try? await taskModelCatalogClient.models(for: provider),
              !models.isEmpty,
              !Task.isCancelled else {
            return
        }
        cacheTaskModels(
            MobileTaskModelListResult(models: models, source: .backend),
            for: key
        )
    }

    private func cacheTaskModels(
        _ result: MobileTaskModelListResult,
        for key: MobileTaskModelCacheKey
    ) {
        taskModelCache[key] = MobileTaskModelCacheEntry(
            result: result,
            fetchedAt: runtime?.now() ?? Date()
        )
    }

    /// Source of the cached catalog, exposed for diagnostics and UI verification.
    public func taskModelListSource(
        provider: MobileTaskAgentProvider,
        macDeviceID: String,
        instanceTag _: String?
    ) -> MobileTaskModelListSource? {
        taskModelCache[
            MobileTaskModelCacheKey(
                macDeviceID: macDeviceID,
                provider: provider
            )
        ]?.result.source
    }

    /// Fetch timestamp used by package tests and cache diagnostics.
    func taskModelsFetchedAt(
        provider: MobileTaskAgentProvider,
        macDeviceID: String,
        instanceTag _: String?
    ) -> Date? {
        taskModelCache[
            MobileTaskModelCacheKey(
                macDeviceID: macDeviceID,
                provider: provider
            )
        ]?.fetchedAt
    }
}
