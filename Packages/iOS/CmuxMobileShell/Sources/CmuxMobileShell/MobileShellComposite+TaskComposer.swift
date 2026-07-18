internal import CmuxMobilePairedMac
public import CmuxMobileRPC
public import CmuxMobileShellModel
internal import Foundation

/// A user-actionable failure returned by task-composer directory search.
public enum MobileTaskDirectorySearchFailure: Error, Equatable, Sendable {
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
}

extension MobileShellComposite {
    /// Returns matching Mac directories with explicit index and filesystem coverage.
    public func searchTaskDirectories(
        macDeviceID: String,
        query rawQuery: String
    ) async -> Result<MobileTaskDirectorySearchResponse, MobileTaskDirectorySearchFailure> {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return .success(MobileTaskDirectorySearchResponse(
                directories: [],
                searchScope: .contextualCandidatesOnly
            ))
        }
        if macDeviceID != foregroundMacDeviceID || remoteClient == nil {
            guard await switchToMac(macDeviceID: macDeviceID) else { return .failure(.unavailable) }
        }
        guard !Task.isCancelled, foregroundMacDeviceID == macDeviceID,
              let client = remoteClient else { return .failure(.cancelled) }
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
            guard !Task.isCancelled, foregroundMacDeviceID == macDeviceID else {
                return .failure(.cancelled)
            }
            return .success(try MobileTaskDirectorySearchResponse.decode(data))
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
                return .failure(.unsupported)
            case .requestTimedOut,
                 .rpcError("request_timeout", _):
                return .failure(.timedOut)
            case .authorizationFailed,
                 .accountMismatch,
                 .rpcError("unauthorized", _),
                 .rpcError("forbidden", _),
                 .rpcError("account_mismatch", _):
                return .failure(.authorizationRequired)
            case .rpcError("cancelled", _):
                return .failure(.cancelled)
            case .connectionClosed,
                 .transportWriteTimedOut,
                 .insecureManualRoute,
                 .attachTicketExpired:
                return .failure(.unavailable)
            case .invalidResponse,
                 .rpcError:
                return .failure(.rejected)
            }
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.rejected)
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
            return false
        }
        taskTemplateStore?.setComposerDraft(draft)
        return taskTemplateStore != nil
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
        guard isSignedIn, capturedGeneration == currentSessionGeneration,
              let taskTemplateStore else {
            return false
        }
        taskTemplateStore.setComposerDraft(nil)
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
        guard isSignedIn, capturedGeneration == currentSessionGeneration,
              let taskTemplateStore else {
            return false
        }
        taskTemplateStore.setLastTemplateID(snapshot.templateID)
        taskTemplateStore.setLastMacDeviceID(snapshot.macDeviceID)
        taskTemplateStore.setLastDirectory(
            snapshot.trimmedDirectory.isEmpty ? nil : snapshot.trimmedDirectory,
            macDeviceID: snapshot.macDeviceID
        )
        if !snapshot.trimmedDirectory.isEmpty {
            taskTemplateStore.recordRecentDirectory(
                snapshot.trimmedDirectory,
                macDeviceID: snapshot.macDeviceID,
                at: Date()
            )
        }
        taskTemplateStore.setComposerDraft(nil)
        return true
    }

    /// Submit a task-composer workspace create request to the selected Mac.
    /// - Parameters:
    ///   - macDeviceID: Target Mac device id.
    ///   - spec: Workspace-create parameters derived from the selected template.
    ///   - willStartCreate: Optional main-actor callback invoked after the target
    ///     Mac and capability are resolved, immediately before the create begins.
    /// - Returns: `success` when the workspace was created; otherwise the failure to display.
    @discardableResult
    public func submitTaskComposer(
        macDeviceID: String,
        spec: MobileWorkspaceCreateSpec,
        willStartCreate: (@MainActor () -> Void)? = nil
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        // A dropped connection can leave `foregroundMacDeviceID` pointing at the
        // selected Mac while `remoteClient` is already gone; a matching id alone
        // must not skip the switch, or the create fails as not-connected without
        // ever attempting a re-dial. `switchToMac` short-circuits when the
        // foreground connection to this Mac is genuinely live.
        if macDeviceID != foregroundMacDeviceID || remoteClient == nil {
            guard await switchToMac(macDeviceID: macDeviceID) else {
                return .failure(.notConnected(hostDisplayName: taskComposerTargetName(macDeviceID: macDeviceID)))
            }
        }
        guard !Task.isCancelled else {
            return .failure(.notConnected(hostDisplayName: taskComposerTargetName(macDeviceID: macDeviceID)))
        }
        guard let pinnedContext = captureWorkspaceCreateContext(),
              pinnedContext.macDeviceID == macDeviceID else {
            return .failure(.notConnected(hostDisplayName: taskComposerTargetName(macDeviceID: macDeviceID)))
        }
        guard pinnedContext.supportedHostCapabilities.contains(Self.taskCreateCapability) else {
            return .failure(.unsupported(hostDisplayName: taskComposerTargetName(macDeviceID: macDeviceID)))
        }
        guard !Task.isCancelled else {
            return .failure(.notConnected(hostDisplayName: pinnedContext.hostDisplayName))
        }
        return await createWorkspaceRequest(
            spec: spec,
            pinnedContext: pinnedContext,
            willStartCreate: willStartCreate
        )
    }

    private func taskComposerTargetName(macDeviceID: String) -> String {
        displayPairedMacs.first { $0.macDeviceID == macDeviceID }?.resolvedName
            ?? pairedMacs.first { $0.macDeviceID == macDeviceID }?.resolvedName
            ?? macDeviceID
    }
}
