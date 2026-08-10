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
        if !matchesForegroundPairing(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ) || remoteClient == nil {
            guard await switchToMac(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            ) else {
                return .failure(.notConnected(
                    hostDisplayName: taskComposerTargetName(
                        macDeviceID: macDeviceID,
                        instanceTag: instanceTag
                    )
                ))
            }
        }
        guard !Task.isCancelled,
              let context = captureWorkspaceCreateContext(),
              context.macDeviceID == macDeviceID,
              instanceTag == nil || context.instanceTag == instanceTag else {
            return .failure(.notConnected(
                hostDisplayName: taskComposerTargetName(
                    macDeviceID: macDeviceID,
                    instanceTag: instanceTag
                )
            ))
        }
        guard context.supportedHostCapabilities.contains(
            Self.taskAttachmentCapability
        ) else {
            return .failure(.unsupported(hostDisplayName: context.hostDisplayName))
        }

        guard attachment.byteCount <= TaskComposerAttachment.maximumFileBytes else {
            return .failure(.rejected(hostDisplayName: context.hostDisplayName))
        }

        do {
            let receipt = try await MobileAttachmentRPCUploader(client: context.client).upload(
                fileURL: attachment.localStagedFileURL,
                byteCount: attachment.byteCount,
                fileName: attachment.displayName,
                operationID: operationID,
                uploadID: attachment.id
            )
            guard context.isCurrent(
                macDeviceID: foregroundMacDeviceID,
                instanceTag: activeMacInstanceTag,
                client: remoteClient,
                generation: connectionGeneration
            ), isSignedIn else {
                return .failure(.notConnected(hostDisplayName: context.hostDisplayName))
            }
            return .success(receipt.hostPath)
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
            return .failure(
                workspaceMutationFailure(
                    error,
                    hostDisplayName: context.hostDisplayName
                )
            )
        }
    }

}
