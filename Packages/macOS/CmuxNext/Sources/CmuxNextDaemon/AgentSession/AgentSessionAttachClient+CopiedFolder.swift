public import Foundation

extension AgentSessionAttachClient {
    /// A Cloud chat start's copy of a folder this Mac already trusts (`cmux link start-chat copy`'s
    /// `source_trusted`, read from this Mac's acpmux): records the same answer, `trusted`, for the copy
    /// on the person's own Cloud machine (`agent-session-trust` on the chat's tab `surface`, sent only
    /// on the link's owner answer, `ownerLink`), so their first message is not held behind a second
    /// "Trust repo?" for their own copy (capture at ff3f8c9b, 2026-11-01).
    ///
    /// This narrows cx-1bhjj, where only the person's click on that machine trusts one of its folders:
    /// here the click they gave this Mac for the same folder counts for its copy, and for nothing else.
    /// Nothing is sent unless `sourceTrusted`, and never for a machine that is not the caller's own
    /// (no `ownerLink`). A folder this Mac does not trust is still asked about there. Fails quietly: the
    /// page then asks as before. Answers whether the machine recorded it.
    @discardableResult
    public static func trustCopiedFolder(_ cwd: String?, sourceTrusted: Bool, surface: UInt64, ownerLink: OwnerLink?,
                                         endpoint: @escaping EndpointProvider) async -> Bool {
        guard sourceTrusted, let cwd, cwd.hasPrefix("/"), let ownerLink else { return false }
        let client = AgentSessionAttachClient(surface: surface, endpoint: endpoint)
        let recorded = (try? await client.trust(cwd: cwd, level: "trusted", ownerLink: ownerLink)) != nil
        await client.close()
        return recorded
    }
}
