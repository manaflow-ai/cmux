internal import CmuxMobileRPC
internal import Foundation
internal import OSLog

private let compatibleMacTagsLog = Logger(
    subsystem: "com.cmuxterm.mobile",
    category: "compatible-mac-tags"
)

/// The `mobile.compatible_tags.changed` event payload: the Mac's full grant
/// set after a change, so application is idempotent and order-independent.
private struct MobileCompatibleMacTagsEvent: Decodable {
    let tags: [String]

    static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

@MainActor
extension MobileShellComposite {
    /// Applies a live grant-set change pushed by the connected foreground Mac.
    func handleCompatibleMacTagsChangedEvent(
        _ event: MobileEventEnvelope
    ) async {
        guard
            let json = event.payloadJSON,
            let payload = try? MobileCompatibleMacTagsEvent.decode(json)
        else { return }
        await applyAdvertisedCompatibleMacTags(
            payload.tags,
            reportedInstanceTag: activeMacInstanceTag
        )
    }

    /// Adopts the Mac-advertised sibling-tag grant set into this build's
    /// runtime allowlist, then reconciles everything the policy gates.
    ///
    /// Only this build's exact-tag Mac is a grant authority: a sibling Mac
    /// admitted through the allowlist must not be able to extend the allowlist
    /// further, so a mismatched reporter is ignored rather than applied.
    ///
    /// On a real change, one full aggregation pass both prunes (a revoked
    /// tag's Mac drops out of the policy-scoped store load, so its
    /// subscription and cached UI state tear down) and admits (zero-touch
    /// discovery dials newly granted tags).
    func applyAdvertisedCompatibleMacTags(
        _ tags: [String]?,
        reportedInstanceTag: String?
    ) async {
        guard let tags,
              let policy = buildCompatibilityPolicy,
              let allowlist = policy.developmentAdditionalInstanceTags,
              let expectedTag = policy.developmentExpectedInstanceTag,
              let normalizedReportedTag = MobileMacTagAllowlist.normalized(
                  reportedInstanceTag
              ),
              normalizedReportedTag == MobileMacTagAllowlist.normalized(
                  expectedTag
              )
        else { return }
        guard allowlist.replace(with: tags) else { return }
        compatibleMacTagsLog.info(
            "compatible mac tags updated tags=\(allowlist.tags.sorted().joined(separator: ","), privacy: .public)"
        )
        await loadPairedMacs()
        scheduleSecondaryAggregation(discoverLivePeers: true)
    }
}
