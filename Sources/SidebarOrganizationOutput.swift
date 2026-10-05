import CmuxExtensionKit
import Foundation

/// Engine diagnostics are objects; absence of proposals is not a decoding failure.
struct SidebarOrganizationOutput: Codable, Equatable, Sendable {
    struct Diagnostic: Codable, Equatable, Sendable {
        let code: String
        var workspaceId: String? = nil
        var message: String? = nil
    }
    struct Evidence: Codable, Equatable, Sendable {
        let kind: String
        let reference: String
        var sessionId: String? = nil
    }
    struct Proposal: Codable, Equatable, Sendable {
        let workspaceId: String
        let expectedRevision: UInt64
        let id: UUID
        let suggestedTags: [CmuxSidebarContextTag]
        let suggestedTitle: String?
        let summary: String?
        let source: String
        let sourceFingerprint: String
        let conversationIDs: [String]
        let analyzedAt: Date
        let evidence: [Evidence]?

        var isValid: Bool {
            suggestedTags.count <= 128 && Set(suggestedTags.map(\.id)).count == suggestedTags.count
                && conversationIDs.count <= 64 && Set(conversationIDs).count == conversationIDs.count
                && (suggestedTitle?.count ?? 0) <= 512 && (summary?.count ?? 0) <= 2_000
                && !source.isEmpty && source.count <= 128 && !sourceFingerprint.isEmpty && sourceFingerprint.count <= 256
                && suggestedTags.allSatisfy { !$0.id.isEmpty && $0.id.count <= 256 && !$0.label.isEmpty && $0.label.count <= 128 && !$0.dimension.isEmpty && $0.dimension.count <= 64 }
        }

        var contextProposal: CmuxSidebarWorkspaceContextProposal {
            .init(id: id, suggestedTags: suggestedTags, suggestedTitle: suggestedTitle,
                  summary: summary, source: source, sourceFingerprint: sourceFingerprint,
                  conversationIDs: conversationIDs, analyzedAt: analyzedAt)
        }
    }
    let schemaVersion: Int
    let proposals: [Proposal]
    let diagnostics: [Diagnostic]
}
