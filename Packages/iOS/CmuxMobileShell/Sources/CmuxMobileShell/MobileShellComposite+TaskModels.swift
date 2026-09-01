internal import CmuxMobileRPC
public import CmuxMobileShellModel
import Foundation

private enum MobileTaskModelRefreshEvent: Sendable {
    case host(MobileTaskModelListResult?)
    case backend(MobileTaskModelListResult?)
}

private struct MobileTaskModelRequestContext {
    enum Owner {
        case foreground(generation: UUID)
        case focused(ownerKey: MacPairingKey, generation: UUID)
        case control(ownerKey: MacPairingKey, subscription: SecondaryMacSubscription)
    }

    let client: MobileCoreRPCClient
    let owner: Owner
}

extension MobileShellComposite {
    /// Identity of the live read connection currently serving one paired Mac.
    ///
    /// The identity stays stable when the same client moves between focused
    /// and control roles, changes when that client is replaced, and is `nil`
    /// until a usable client has been published. Composer discovery observes
    /// this value so a backend-only refresh is retried when the host becomes
    /// reachable, without changing the foreground Mac.
    public func taskModelConnectionIdentity(
        macDeviceID: String,
        instanceTag: String?
    ) -> String? {
        captureTaskModelRequestContext(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )?.client.instanceID
    }

    /// Resolves a secondary control subscription for one exact pairing.
    /// A missing tag names only a legacy untagged row. It never selects an
    /// arbitrary Stable/Nightly sibling on the same physical Mac.
    func controlSubscriptionMatching(
        macDeviceID: String,
        instanceTag: String?
    ) -> SecondaryMacSubscription? {
        let probe = MacPairingKey(macDeviceID: macDeviceID, instanceTag: instanceTag)
        return secondaryMacSubscriptions[probe]
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
        guard !Task.isCancelled,
              var context = captureTaskModelRequestContext(
                  macDeviceID: macDeviceID,
                  instanceTag: instanceTag
              ) else {
            throw MobileShellConnectionError.connectionClosed
        }
        let sessionGeneration = currentSessionGeneration
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.task.models.list",
            params: ["provider": provider.rawValue]
        )
        var response: Data?

        // A terminal-stream recovery can replace the focused client without
        // changing the selected Mac or tag. Re-resolve once from the
        // connection registry when that exact ownership handoff races this
        // read. This is state-driven and never waits or changes focus.
        for attempt in 0..<2 {
            do {
                response = try await context.client.sendRequest(
                    request,
                    // Claude's installed-agent control request is intentionally
                    // bounded at 30 seconds on the Mac. Leave transport headroom;
                    // the concurrent backend catalog keeps the picker responsive.
                    timeoutNanoseconds: 35_000_000_000
                )
                break
            } catch {
                guard !Task.isCancelled else { throw error }
                if attempt == 0,
                   !isCurrentTaskModelRequestContext(
                       context,
                       macDeviceID: macDeviceID,
                       instanceTag: instanceTag
                   ),
                   let replacement = captureTaskModelRequestContext(
                       macDeviceID: macDeviceID,
                       instanceTag: instanceTag
                   ),
                   replacement.client !== context.client {
                    context = replacement
                    continue
                }
                if isCurrentTaskModelRequestContext(
                    context,
                    macDeviceID: macDeviceID,
                    instanceTag: instanceTag
                ), case .foreground(let generation) = context.owner {
                    handleMacAvailabilityFailureIfCurrent(
                        after: error,
                        expectedClient: context.client,
                        expectedGeneration: generation
                    )
                }
                throw error
            }
        }

        guard !Task.isCancelled,
              isSignedIn,
              currentSessionGeneration == sessionGeneration,
              let response else {
            throw MobileShellConnectionError.invalidResponse
        }
        guard let object = try JSONSerialization.jsonObject(with: response)
                as? [String: Any],
              let rawSource = object["source"] as? String,
              let source = MobileTaskModelListSource(rawValue: rawSource),
              let rawModels = object["models"] as? [[String: Any]] else {
            throw MobileShellConnectionError.invalidResponse
        }
        let discoveryError: MobileTaskModelListError?
        if let rawError = object["error"] {
            guard let rawError = rawError as? String,
                  let parsedError = MobileTaskModelListError(rawValue: rawError) else {
                throw MobileShellConnectionError.invalidResponse
            }
            discoveryError = parsedError
        } else {
            discoveryError = nil
        }
        func parseModel(_ rawModel: [String: Any]) throws -> MobileTaskAgentModel {
            guard let id = rawModel["id"] as? String,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let displayName = rawModel["display_name"] as? String,
                  !displayName.isEmpty else {
                throw MobileShellConnectionError.invalidResponse
            }
            let rawEfforts = rawModel["efforts"] as? [[String: Any]] ?? []
            var seenEffortIDs: Set<String> = []
            var efforts: [MobileTaskAgentEffort] = []
            efforts.reserveCapacity(rawEfforts.count)
            for rawEffort in rawEfforts {
                guard let effortID = rawEffort["id"] as? String,
                      !effortID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let effortDisplayName = rawEffort["display_name"] as? String,
                      !effortDisplayName.isEmpty,
                      seenEffortIDs.insert(effortID).inserted else {
                    throw MobileShellConnectionError.invalidResponse
                }
                efforts.append(MobileTaskAgentEffort(
                    id: effortID,
                    displayName: effortDisplayName,
                    description: rawEffort["description"] as? String
                ))
            }
            return MobileTaskAgentModel(
                id: id,
                displayName: displayName,
                efforts: efforts,
                defaultEffortID: rawModel["default_effort_id"] as? String
            )
        }
        var models: [MobileTaskAgentModel] = []
        models.reserveCapacity(rawModels.count)
        var seenIDs: Set<String> = []
        for rawModel in rawModels {
            let model = try parseModel(rawModel)
            guard seenIDs.insert(model.id).inserted else {
                throw MobileShellConnectionError.invalidResponse
            }
            models.append(model)
        }
        let defaultModel: MobileTaskAgentModel?
        if let rawDefaultModel = object["default_model"] as? [String: Any] {
            defaultModel = try parseModel(rawDefaultModel)
        } else {
            defaultModel = nil
        }
        return MobileTaskModelListResult(
            models: models,
            source: source,
            defaultModel: defaultModel,
            error: discoveryError
        )
    }

    private func captureTaskModelRequestContext(
        macDeviceID: String,
        instanceTag: String?
    ) -> MobileTaskModelRequestContext? {
        // `remoteClient` is the focused command owner. Its terminal health can
        // be reconnecting while the RPC transport remains usable, so this
        // read-only probe intentionally does not depend on `connectionState`.
        if matchesForegroundPairing(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ), let remoteClient {
            return MobileTaskModelRequestContext(
                client: remoteClient,
                owner: .foreground(generation: connectionGeneration)
            )
        }
        if let connection = focusedConnectionMatching(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ) {
            return MobileTaskModelRequestContext(
                client: connection.client,
                owner: .focused(
                    ownerKey: connection.ownerKey,
                    generation: connection.generation
                )
            )
        }
        if let subscription = controlSubscriptionMatching(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ) {
            return MobileTaskModelRequestContext(
                client: subscription.client,
                owner: .control(
                    ownerKey: subscription.ownerKey,
                    subscription: subscription
                )
            )
        }
        return nil
    }

    private func focusedConnectionMatching(
        macDeviceID: String,
        instanceTag: String?
    ) -> MacConnection? {
        let key = MacPairingKey(macDeviceID: macDeviceID, instanceTag: instanceTag)
        guard let connection = connections[key] else { return nil }
        guard macInstanceTagAuthority.sameStoredAuthority(
            connection.storedInstanceTag,
            instanceTag
        ) || macInstanceTagAuthority.sameStoredAuthority(
            connection.authenticatedInstanceTag,
            instanceTag
        ) else {
            return nil
        }
        return connection
    }

    private func isCurrentTaskModelRequestContext(
        _ context: MobileTaskModelRequestContext,
        macDeviceID: String,
        instanceTag: String?
    ) -> Bool {
        switch context.owner {
        case .foreground(let generation):
            return generation == connectionGeneration
                && context.client === remoteClient
                && matchesForegroundPairing(
                    macDeviceID: macDeviceID,
                    instanceTag: instanceTag
                )
        case .focused(let ownerKey, let generation):
            guard let connection = connections[ownerKey] else { return false }
            return connection.client === context.client
                && connection.generation == generation
        case .control(let ownerKey, let subscription):
            return secondaryMacSubscriptions[ownerKey] === subscription
                && subscription.client === context.client
        }
    }

    /// Returns cached models synchronously for composer rendering and restore.
    ///
    /// - Parameters:
    ///   - provider: Coding-agent provider to resolve.
    ///   - macDeviceID: Physical Mac selected in the task composer.
    ///   - instanceTag: Exact paired instance. Stable and Nightly keep separate
    ///     discovery results even when their physical device id is shared.
    /// - Returns: Previously fetched models, or `nil`.
    public func discoveredTaskModels(
        provider: MobileTaskAgentProvider,
        macDeviceID: String,
        instanceTag: String?
    ) -> [MobileTaskAgentModel]? {
        discoveredTaskModelResult(
            provider: provider,
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )?.models
    }

    /// Returns the cached model list and implicit Default metadata together.
    public func discoveredTaskModelResult(
        provider: MobileTaskAgentProvider,
        macDeviceID: String,
        instanceTag: String?
    ) -> MobileTaskModelListResult? {
        taskModelCache[
            MobileTaskModelCacheKey(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag,
                provider: provider
            )
        ]?.result
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
            instanceTag: instanceTag,
            hostResultLoader: { [weak self] in
                guard let self else { return nil }
                do {
                    return try await self.fetchTaskModels(
                        provider: provider,
                        macDeviceID: macDeviceID,
                        instanceTag: instanceTag
                    )
                } catch {
                    return MobileTaskModelListResult(
                        models: [],
                        source: .fallback,
                        error: .hostUnavailable
                    )
                }
            },
            didUpdate: didUpdate
        )
    }

    private func refreshTaskModels(
        provider: MobileTaskAgentProvider,
        macDeviceID: String,
        instanceTag: String? = nil,
        hostResultLoader: @escaping @Sendable () async -> MobileTaskModelListResult?,
        didUpdate: (@MainActor (MobileTaskModelListResult) -> Void)? = nil
    ) async {
        let key = MobileTaskModelCacheKey(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            provider: provider
        )
        let catalogClient = taskModelCatalogClient
        var hostFailure: MobileTaskModelListResult?
        var backendResult: MobileTaskModelListResult?
        await withTaskGroup(of: MobileTaskModelRefreshEvent.self) { group in
            group.addTask {
                .host(await hostResultLoader())
            }
            group.addTask {
                .backend(try? await catalogClient.result(for: provider))
            }

            for await event in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                switch event {
                case .host(let result):
                    guard let result else {
                        continue
                    }
                    if let error = result.error {
                        hostFailure = result
                        if let backendResult, backendResult.error == nil {
                            let visibleResult = resultWithError(
                                backendResult,
                                with: error
                            )
                            self.cacheTaskModels(visibleResult, for: key)
                            didUpdate?(visibleResult)
                        }
                        continue
                    }
                    guard result.source == .discovered,
                          !result.models.isEmpty || result.defaultModel != nil else {
                        continue
                    }
                    cacheTaskModels(result, for: key)
                    didUpdate?(result)
                    group.cancelAll()
                    return
                case .backend(let models):
                    guard let result = models,
                          !result.models.isEmpty,
                          taskModelCache[key]?.result.source != .discovered else {
                        continue
                    }
                    let visibleResult = resultWithError(
                        result,
                        with: hostFailure?.error
                    )
                    backendResult = visibleResult
                    cacheTaskModels(visibleResult, for: key)
                    didUpdate?(visibleResult)
                }
            }
            if let hostFailure, backendResult == nil {
                cacheTaskModels(hostFailure, for: key)
                didUpdate?(hostFailure)
            }
        }
    }

    private func resultWithError(
        _ result: MobileTaskModelListResult,
        with error: MobileTaskModelListError?
    ) -> MobileTaskModelListResult {
        guard let error else { return result }
        return MobileTaskModelListResult(
            models: result.models,
            source: result.source,
            defaultModel: result.defaultModel,
            error: error
        )
    }

    /// Applies the source-priority policy through an injectable host result.
    /// Kept internal so package tests can prove that authoritative agent data
    /// performs zero backend requests and legacy host fallbacks do not leak in.
    func refreshTaskModels(
        provider: MobileTaskAgentProvider,
        macDeviceID: String,
        instanceTag: String? = nil,
        hostResult: MobileTaskModelListResult?
    ) async {
        let key = MobileTaskModelCacheKey(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            provider: provider
        )
        if let hostResult,
           hostResult.source == .discovered,
           !hostResult.models.isEmpty || hostResult.defaultModel != nil {
            guard !Task.isCancelled else { return }
            cacheTaskModels(hostResult, for: key)
            return
        }

        guard !Task.isCancelled,
              let result = try? await taskModelCatalogClient.result(for: provider),
              !result.models.isEmpty,
              !Task.isCancelled else {
            return
        }
        cacheTaskModels(result, for: key)
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
        instanceTag: String?
    ) -> MobileTaskModelListSource? {
        taskModelCache[
            MobileTaskModelCacheKey(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag,
                provider: provider
            )
        ]?.result.source
    }

    /// Fetch timestamp used by package tests and cache diagnostics.
    func taskModelsFetchedAt(
        provider: MobileTaskAgentProvider,
        macDeviceID: String,
        instanceTag: String?
    ) -> Date? {
        taskModelCache[
            MobileTaskModelCacheKey(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag,
                provider: provider
            )
        ]?.fetchedAt
    }
}
