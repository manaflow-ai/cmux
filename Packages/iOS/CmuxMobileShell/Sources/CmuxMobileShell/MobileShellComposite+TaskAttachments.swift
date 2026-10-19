internal import CMUXMobileCore
internal import CmuxMobileRPC
public import CmuxMobileShellModel
public import Foundation

extension MobileShellComposite {
    /// Whether the selected Mac instance currently advertises task attachments.
    ///
    /// - Parameters:
    ///   - macDeviceID: Physical Mac selected in the task composer.
    ///   - instanceTag: Exact paired app instance, when known.
    /// - Returns: `true` only for a matching host capability announcement.
    public func supportsTaskAttachments(
        macDeviceID: String,
        instanceTag: String?
    ) -> Bool {
        if matchesForegroundPairing(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ) {
            return supportedHostCapabilities.contains(Self.taskAttachmentCapability)
        }
        if let subscription = controlSubscriptionMatching(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ) {
            return subscription.supportedHostCapabilities.contains(
                Self.taskAttachmentCapability
            )
        }
        let aliases = pairedMacAliasIDs(
            for: macDeviceID,
            instanceTag: instanceTag
        )
        if let instanceTag {
            return aliases.contains {
                presenceMap.instance(deviceId: $0, tag: instanceTag)?
                    .capabilities.contains(Self.taskAttachmentCapability) == true
            }
        }
        return aliases.contains {
            presenceMap.soleRouteAdvertisingInstance(deviceId: $0)?
                .capabilities.contains(Self.taskAttachmentCapability) == true
        }
    }

    /// Uploads one staged task attachment to the selected Mac in 3 MiB chunks.
    ///
    /// - Parameters:
    ///   - attachment: App-owned staged attachment file.
    ///   - operationID: Task submission idempotency key.
    ///   - macDeviceID: Target Mac device id.
    ///   - instanceTag: Exact paired app instance, when known.
    /// - Returns: The final absolute Mac path, or a user-actionable failure.
    public func uploadTaskAttachment(
        _ attachment: TaskComposerAttachment,
        operationID: UUID,
        macDeviceID: String,
        instanceTag: String?
    ) async -> Result<String, MobileWorkspaceMutationFailure> {
        let diagnosticStartedAt = appDiagnosticNow()
        let diagnosticCorrelationID = attachment.id.uuidString
        recordAppEvent(
            .attachmentPreparationStarted,
            correlationID: diagnosticCorrelationID
        )
        func fail(
            _ failure: MobileWorkspaceMutationFailure
        ) -> Result<String, MobileWorkspaceMutationFailure> {
            recordAppEvent(
                .taskAttachmentPreparationFailed,
                correlationID: diagnosticCorrelationID,
                startedAt: diagnosticStartedAt,
                failure: failure.diagnosticFailureKind
            )
            return .failure(failure)
        }
        if !matchesForegroundPairing(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ) || remoteClient == nil {
            guard await switchToMac(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            ) else {
                return fail(.notConnected(
                    hostDisplayName: taskComposerTargetName(
                        macDeviceID: macDeviceID,
                        instanceTag: instanceTag
                    )
                ))
            }
        }
        guard !Task.isCancelled,
              let context = captureWorkspaceCreateContext(),
              context.matchesTarget(
                  macDeviceID: macDeviceID,
                  instanceTag: instanceTag
              ) else {
            return fail(.notConnected(
                hostDisplayName: taskComposerTargetName(
                    macDeviceID: macDeviceID,
                    instanceTag: instanceTag
                )
            ))
        }
        guard context.supportedHostCapabilities.contains(
            Self.taskAttachmentCapability
        ) else {
            return fail(.unsupported(hostDisplayName: context.hostDisplayName))
        }

        let data: Data
        do {
            data = try await loadTaskAttachmentData(
                from: attachment.localStagedFileURL
            )
        } catch {
            return fail(.rejected(hostDisplayName: context.hostDisplayName))
        }
        guard data.count == attachment.byteCount,
              data.count <= TaskComposerAttachment.maximumFileBytes else {
            return fail(.rejected(hostDisplayName: context.hostDisplayName))
        }

        let plan = MobileTaskAttachmentChunkPlan(totalByteCount: data.count)
        do {
            var finalPath: String?
            for (index, range) in plan.ranges.enumerated() {
                try Task.checkCancellation()
                let isLast = index == plan.ranges.count - 1
                let params: [String: Any] = [
                    "operation_id": operationID.uuidString,
                    "upload_id": attachment.id.uuidString,
                    "file_name": attachment.displayName,
                    "total_bytes": data.count,
                    "offset": range.lowerBound,
                    "data_b64": data.subdata(in: range).base64EncodedString(),
                    "last": isLast,
                ]
                let response = try await context.client.sendRequest(
                    MobileCoreRPCClient.requestData(
                        method: "mobile.task.attachment.upload",
                        params: params
                    )
                )
                guard context.isCurrent(
                    macDeviceID: foregroundMacDeviceID,
                    instanceTag: activeMacInstanceTag,
                    client: remoteClient,
                    generation: connectionGeneration
                ), isSignedIn else {
                    return fail(.notConnected(
                        hostDisplayName: context.hostDisplayName
                    ))
                }
                guard let object = try JSONSerialization.jsonObject(with: response)
                        as? [String: Any] else {
                    throw MobileShellConnectionError.invalidResponse
                }
                if isLast {
                    guard let path = object["path"] as? String,
                          path.hasPrefix("/") else {
                        throw MobileShellConnectionError.invalidResponse
                    }
                    finalPath = path
                }
            }
            guard let finalPath else {
                return fail(.rejected(hostDisplayName: context.hostDisplayName))
            }
            recordAppEvent(
                .attachmentPreparationSucceeded,
                correlationID: diagnosticCorrelationID,
                startedAt: diagnosticStartedAt,
                count: data.count
            )
            recordAppEvent(
                .taskAttachmentPrepared,
                correlationID: diagnosticCorrelationID,
                count: plan.ranges.count
            )
            return .success(finalPath)
        } catch {
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
            return fail(
                workspaceMutationFailure(
                    error,
                    hostDisplayName: context.hostDisplayName
                )
            )
        }
    }

    private func loadTaskAttachmentData(from url: URL) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask(priority: .utility) {
                try Task.checkCancellation()
                return try Data(contentsOf: url, options: .mappedIfSafe)
            }
            guard let data = try await group.next() else {
                throw CancellationError()
            }
            return data
        }
    }
}
