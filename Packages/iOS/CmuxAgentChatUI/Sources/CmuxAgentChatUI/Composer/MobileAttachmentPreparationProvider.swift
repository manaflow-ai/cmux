import CmuxMobileSupport

/// Constructor-injected staging seam used by deterministic composer hosts.
public typealias MobileAttachmentPreparationProvider = @MainActor () async -> MobileStagedAttachment?
