public import CMUXMobileCore
internal import CmuxMobilePairedMac
public import CmuxMobileRPC
public import CmuxMobileShellModel
internal import Foundation

/// A user-actionable failure returned by task-composer directory search.
public enum MobileTaskDirectorySearchFailure: Error, Equatable, Sendable,
    DiagnosticFailureProviding
{
    /// The selected Mac predates task-composer directory search.
    case unsupported
    /// The selected Mac could not be reached.
    case unavailable
    /// The Mac did not finish directory search before its deadline.
    case timedOut
    /// The phone or Mac must be signed in again before search can continue.
    case authorizationRequired
    /// The Mac rejected or could not decode the directory-search request.
    case rejected
    /// The caller superseded or cancelled this search.
    case cancelled

    public var diagnosticFailureKind: DiagnosticFailureKind {
        switch self {
        case .unsupported:
            .policyUnavailable
        case .unavailable:
            .connectionClosed
        case .timedOut:
            .timedOut
        case .authorizationRequired:
            .authorizationFailed
        case .rejected:
            .protocolViolation
        case .cancelled:
            .cancelled
        }
    }
}

extension MobileShellComposite {
    /// Returns matching Mac directories with explicit index and filesystem coverage.
    /// - Parameters:
    ///   - macDeviceID: Physical Mac that owns the filesystem.
    ///   - instanceTag: Exact paired app instance to query, or `nil` for
    ///     legacy device-level routing.
    ///   - rawQuery: User-entered directory search text.
    /// - Returns: Matching directories or a user-actionable failure.
    public func searchTaskDirectories(
        macDeviceID: String,
        instanceTag: String? = nil,
        query rawQuery: String
    ) async -> Result<MobileTaskDirectorySearchResponse, MobileTaskDirectorySearchFailure> {
        let diagnosticStartedAt = appDiagnosticNow()
        recordAppEvent(
            .taskDirectorySearchStarted,
            correlationID: macDeviceID
        )
        func finish(
            _ result: Result<MobileTaskDirectorySearchResponse, MobileTaskDirectorySearchFailure>
        ) -> Result<MobileTaskDirectorySearchResponse, MobileTaskDirectorySearchFailure> {
            switch result {
            case .success(let response):
                recordAppEvent(
                    .taskDirectorySearchSucceeded,
                    correlationID: macDeviceID,
                    startedAt: diagnosticStartedAt,
                    count: response.directories.count
                )
            case .failure(let failure):
                recordAppEvent(
                    .taskDirectorySearchFailed,
                    correlationID: macDeviceID,
                    startedAt: diagnosticStartedAt,
                    failure: failure.diagnosticFailureKind
                )
            }
            return result
        }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return finish(.success(MobileTaskDirectorySearchResponse(
                directories: [],
                searchScope: .contextualCandidatesOnly
            )))
        }
        if !matchesForegroundPairing(macDeviceID: macDeviceID, instanceTag: instanceTag)
            || remoteClient == nil {
            guard await switchToMac(macDeviceID: macDeviceID, instanceTag: instanceTag) else {
                return finish(.failure(.unavailable))
            }
        }
        guard !Task.isCancelled,
              matchesForegroundPairing(macDeviceID: macDeviceID, instanceTag: instanceTag),
              let client = remoteClient else { return finish(.failure(.cancelled)) }
        let generation = connectionGeneration
        // The last learned capability set can be stale after a tagged Mac
        // relaunch. This optional read is safe to probe; genuinely older Macs
        // return an RPC error and the UI keeps its contextual suggestions.
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.directory.search",
                params: ["query": query]
            )
            let data = try await client.sendRequest(request, timeoutNanoseconds: 4_000_000_000)
            guard !Task.isCancelled,
                  matchesForegroundPairing(macDeviceID: macDeviceID, instanceTag: instanceTag) else {
                return finish(.failure(.cancelled))
            }
            return finish(.success(try MobileTaskDirectorySearchResponse.decode(data)))
        } catch let error as MobileShellConnectionError {
            handleMacAvailabilityFailureIfCurrent(
                after: error,
                expectedClient: client,
                expectedGeneration: generation
            )
            switch error {
            case let .rpcError(code, _) where [
                "method_not_found",
                "unknown_method",
                "unsupported_method",
            ].contains(code?.lowercased() ?? ""):
                return finish(.failure(.unsupported))
            case .requestTimedOut,
                 .connectAttemptGated,
                 .rpcError("request_timeout", _):
                return finish(.failure(.timedOut))
            case .authorizationFailed,
                 .accountMismatch,
                 .rpcError("unauthorized", _),
                 .rpcError("forbidden", _),
                 .rpcError("account_mismatch", _):
                return finish(.failure(.authorizationRequired))
            case .rpcError("cancelled", _):
                return finish(.failure(.cancelled))
            case .connectionClosed,
                 .transportWriteTimedOut,
                 .routeCleanupBlocked,
                 .insecureManualRoute,
                 .attachTicketExpired:
                return finish(.failure(.unavailable))
            case .invalidResponse,
                 .rpcError:
                return finish(.failure(.rejected))
            }
        } catch is CancellationError {
            return finish(.failure(.cancelled))
        } catch {
            return finish(.failure(.rejected))
        }
    }

    /// Persists an unsent composer draft only for the signed-in session that
    /// created the sheet. A stale disappearing sheet must not restore the
    /// previous account's draft after sign-out has cleared it.
    /// - Parameters:
    ///   - draft: Draft snapshot to persist.
    ///   - capturedGeneration: ``currentSessionGeneration`` captured when the
    ///     composer sheet was created.
    /// - Returns: `true` when the draft belongs to the active session and was
    ///   handed to the configured template store.
    @discardableResult
    public func persistTaskComposerDraft(
        _ draft: MobileTaskComposerDraft,
        ifSessionGeneration capturedGeneration: Int
    ) -> Bool {
        guard isSignedIn, capturedGeneration == currentSessionGeneration else {
            recordAppEvent(.draftPersistenceFailed, failure: .superseded)
            return false
        }
        guard let taskTemplateStore else {
            recordAppEvent(.draftPersistenceFailed, failure: .localStateUnavailable)
            return false
        }
        taskTemplateStore.setComposerDraft(draft)
        recordAppEvent(.draftSaved)
        return true
    }

    /// Clears the composer draft only for the signed-in session that created
    /// the sheet. A stale cancel or async success must not erase a newer
    /// account's draft.
    /// - Parameter capturedGeneration: ``currentSessionGeneration`` captured
    ///   when the composer sheet was created.
    /// - Returns: `true` when the active session's draft store was cleared.
    @discardableResult
    public func clearTaskComposerDraft(
        ifSessionGeneration capturedGeneration: Int
    ) -> Bool {
        guard isSignedIn, capturedGeneration == currentSessionGeneration else {
            recordAppEvent(.draftPersistenceFailed, failure: .superseded)
            return false
        }
        guard let taskTemplateStore else {
            recordAppEvent(.draftPersistenceFailed, failure: .localStateUnavailable)
            return false
        }
        taskTemplateStore.setComposerDraft(nil)
        recordAppEvent(.draftDeleted)
        return true
    }

    /// Persists successful task-composer defaults and clears the submitted
    /// draft as one generation-checked main-actor transaction. A completion
    /// from a signed-out session must not repopulate the next account's store.
    /// - Parameters:
    ///   - snapshot: Immutable values used by the successful submission.
    ///   - capturedGeneration: ``currentSessionGeneration`` captured when the
    ///     composer sheet was created.
    /// - Returns: `true` when the success belonged to the active session and
    ///   was applied to the configured template store.
    @discardableResult
    public func completeTaskComposerSubmission(
        _ snapshot: MobileTaskSubmissionSnapshot,
        ifSessionGeneration capturedGeneration: Int
    ) -> Bool {
        guard isSignedIn, capturedGeneration == currentSessionGeneration else {
            recordAppEvent(.settingPersistenceFailed, failure: .superseded)
            return false
        }
        guard let taskTemplateStore else {
            recordAppEvent(.settingPersistenceFailed, failure: .localStateUnavailable)
            return false
        }
        taskTemplateStore.setLastTemplateID(snapshot.templateID)
        let pairingID = MobilePairedMac.pairingID(
            macDeviceID: snapshot.macDeviceID,
            instanceTag: snapshot.macInstanceTag
        )
        taskTemplateStore.setLastMacDeviceID(pairingID)
        taskTemplateStore.setLastDirectory(
            snapshot.trimmedDirectory.isEmpty ? nil : snapshot.trimmedDirectory,
            macDeviceID: pairingID
        )
        if !snapshot.trimmedDirectory.isEmpty {
            taskTemplateStore.recordRecentDirectory(
                snapshot.trimmedDirectory,
                macDeviceID: pairingID,
                at: Date()
            )
        }
        taskTemplateStore.setComposerDraft(nil)
        recordAppEvent(.draftDeleted)
        return true
    }

    /// Submit a task-composer workspace create request to the selected Mac.
    /// - Parameters:
    ///   - macDeviceID: Target Mac device id.
    ///   - instanceTag: Exact paired app instance to target, or `nil` for
    ///     legacy device-level routing.
    ///   - spec: Workspace-create parameters derived from the selected template.
    ///   - willStartCreate: Optional main-actor callback invoked after the target
    ///     Mac and capability are resolved, immediately before the create begins.
    /// - Returns: `success` when the workspace was created; otherwise the failure to display.
    @discardableResult
    public func submitTaskComposer(
        macDeviceID: String,
        instanceTag: String? = nil,
        spec: MobileWorkspaceCreateSpec,
        willStartCreate: (@MainActor () -> Void)? = nil
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        let diagnosticStartedAt = appDiagnosticNow()
        recordAppEvent(
            .taskSubmitStarted,
            correlationID: macDeviceID
        )
        func finish(
            _ result: Result<Void, MobileWorkspaceMutationFailure>
        ) -> Result<Void, MobileWorkspaceMutationFailure> {
            switch result {
            case .success:
                recordAppEvent(
                    .taskSubmitSucceeded,
                    correlationID: macDeviceID,
                    startedAt: diagnosticStartedAt
                )
                recordAppEvent(.taskWorkspaceCreated, correlationID: macDeviceID)
                recordAppEvent(.taskAgentLaunched, correlationID: macDeviceID)
            case .failure(let failure):
                recordAppEvent(
                    .taskSubmitFailed,
                    correlationID: macDeviceID,
                    startedAt: diagnosticStartedAt,
                    failure: failure.diagnosticFailureKind
                )
            }
            return result
        }
        // A dropped connection can leave `foregroundMacDeviceID` pointing at the
        // selected Mac while `remoteClient` is already gone; a matching id alone
        // must not skip the switch, or the create fails as not-connected without
        // ever attempting a re-dial. `switchToMac` short-circuits when the
        // foreground connection to this Mac is genuinely live.
        if !matchesForegroundPairing(macDeviceID: macDeviceID, instanceTag: instanceTag)
            || remoteClient == nil {
            guard await switchToMac(macDeviceID: macDeviceID, instanceTag: instanceTag) else {
                return finish(.failure(.notConnected(
                    hostDisplayName: taskComposerTargetName(
                        macDeviceID: macDeviceID,
                        instanceTag: instanceTag
                    )
                )))
            }
        }
        guard !Task.isCancelled else {
            return finish(.failure(.notConnected(
                hostDisplayName: taskComposerTargetName(
                    macDeviceID: macDeviceID,
                    instanceTag: instanceTag
                )
            )))
        }
        guard let pinnedContext = captureWorkspaceCreateContext(),
              MacPairingKey(
                  macDeviceID: pinnedContext.macDeviceID ?? "",
                  instanceTag: pinnedContext.instanceTag
              ) == MacPairingKey(
                  macDeviceID: macDeviceID,
                  instanceTag: instanceTag
              ) else {
            return finish(.failure(.notConnected(
                hostDisplayName: taskComposerTargetName(
                    macDeviceID: macDeviceID,
                    instanceTag: instanceTag
                )
            )))
        }
        guard pinnedContext.supportedHostCapabilities.contains(Self.taskCreateCapability) else {
            return finish(.failure(.unsupported(
                hostDisplayName: taskComposerTargetName(
                    macDeviceID: macDeviceID,
                    instanceTag: instanceTag
                )
            )))
        }
        guard !Task.isCancelled else {
            return finish(.failure(.notConnected(hostDisplayName: pinnedContext.hostDisplayName)))
        }
        return finish(await createWorkspaceRequest(
            spec: spec,
            pinnedContext: pinnedContext,
            willStartCreate: willStartCreate
        ))
    }

    func taskComposerTargetName(macDeviceID: String, instanceTag: String?) -> String {
        displayPairedMacs.first {
            MacPairingKey($0) == MacPairingKey(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            )
        }?.resolvedName
            ?? pairedMacs.first {
                MacPairingKey($0) == MacPairingKey(
                    macDeviceID: macDeviceID,
                    instanceTag: instanceTag
                )
            }?.resolvedName
            ?? macDeviceID
    }

    /// Whether the foreground connection already targets this exact Mac pairing.
    /// A missing tag matches only another untagged legacy pairing.
    func matchesForegroundPairing(macDeviceID: String, instanceTag: String?) -> Bool {
        guard let foregroundMacDeviceID else { return false }
        return MacPairingKey(
            macDeviceID: foregroundMacDeviceID,
            instanceTag: activeMacInstanceTag
        ) == MacPairingKey(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
    }
}
