import CmuxExtensionKit
import Foundation
import Observation

/// Owns accepted project context, analyzed suggestions, and one native undo step.
/// Its revision is independent of the sidebar transport sequence.
@MainActor
@Observable
final class WorkspaceContextModel {
    enum MutationError: Error, Equatable {
        case revisionConflict
        case invalidPayload
        case proposalNotFound
        case undoUnavailable
        case revisionExhausted
    }

    struct TitleUndo: Codable, Equatable, Sendable {
        var previousCustomTitle: String?
        var previousSource: String?
        var appliedCustomTitle: String
    }

    struct Undo: Codable, Equatable, Sendable {
        var context: CmuxSidebarWorkspaceContext
        var title: TitleUndo?
    }

    struct Persisted: Codable, Equatable, Sendable {
        var context: CmuxSidebarWorkspaceContext
        var undo: Undo?
    }

    struct PreparedChange {
        var context: CmuxSidebarWorkspaceContext
        var previousContext: CmuxSidebarWorkspaceContext
        var suggestedTitle: String?
    }

    private(set) var context = CmuxSidebarWorkspaceContext()
    @ObservationIgnored private var undo: Undo?
    @ObservationIgnored private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    var persisted: Persisted { Persisted(context: context, undo: undo) }

    /// Restoring older manifests creates an empty context without invented aliases.
    func restore(_ persisted: Persisted?) {
        let value = persisted ?? Persisted(context: CmuxSidebarWorkspaceContext(), undo: nil)
        context = value.context
        undo = value.undo
        context.canUndo = undo != nil
        notifyChanged()
    }

    /// Emits after committed changes so extension snapshots are always authoritative.
    func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.observers[id] = nil }
            }
        }
    }

    /// Called by the canonical native rename setter, including non-Cortex edits.
    func recordRename(from previous: String, to current: String) {
        guard previous != current, context.revision < UInt64.max else { return }
        var next = context
        appendAlias(previous, excluding: current, to: &next)
        next.revision += 1
        next.canUndo = false
        undo = nil
        context = next
        notifyChanged()
    }

    func mutate(expectedRevision: UInt64, mutation: CmuxSidebarWorkspaceContextMutation) throws {
        try verify(expectedRevision)
        var next = context
        switch mutation {
        case .setManualTag(let input):
            var tag = try normalizedTag(input)
            tag.origin = .manual
            next.tags.removeAll { $0.id == tag.id || ($0.origin == .automatic && $0.dimension == tag.dimension) }
            next.tags.append(tag)
            guard next.tags.count <= 128 else { throw MutationError.invalidPayload }
        case .removeTag(let id):
            try validateID(id)
            if next.tags.contains(where: { $0.id == id && $0.origin == .automatic }) {
                next.rejectedAutomaticTagIDs = try rejectionIDs(next.rejectedAutomaticTagIDs + [id])
            }
            next.tags.removeAll { $0.id == id }
        case .setSummary(let summary):
            next.summary = try normalizedText(summary, limit: 2_000)
        case .removeAlias(let alias):
            guard alias.count <= 512 else { throw MutationError.invalidPayload }
            next.aliases.removeAll { $0 == alias }
        case .rejectAutomaticTags(let ids):
            next.rejectedAutomaticTagIDs = try rejectionIDs(next.rejectedAutomaticTagIDs + ids)
            let rejected = Set(ids)
            next.tags.removeAll { $0.origin == .automatic && rejected.contains($0.id) }
        case .clearAutomaticTagRejections(let ids):
            if let ids {
                for id in ids { try validateID(id) }
                let cleared = Set(ids)
                next.rejectedAutomaticTagIDs.removeAll { cleared.contains($0) }
            } else {
                next.rejectedAutomaticTagIDs = []
            }
        case .rejectProposal(let id):
            guard let proposal = next.analyzedProposal, proposal.id == id else { throw MutationError.proposalNotFound }
            next.rejectedSourceFingerprints = try rejectionIDs(next.rejectedSourceFingerprints + [proposal.sourceFingerprint])
            next.analyzedProposal = nil
        case .clearProposalRejections(let fingerprints):
            if let fingerprints {
                for fingerprint in fingerprints { try validateID(fingerprint) }
                let cleared = Set(fingerprints)
                next.rejectedSourceFingerprints.removeAll { cleared.contains($0) }
            } else {
                next.rejectedSourceFingerprints = []
            }
        }
        commit(next, previous: context, titleUndo: nil)
    }

    func storeProposal(expectedRevision: UInt64, proposal: CmuxSidebarWorkspaceContextProposal) throws {
        try verify(expectedRevision)
        var next = context
        let proposal = try normalizedProposal(proposal)
        guard !next.rejectedSourceFingerprints.contains(proposal.sourceFingerprint) else { throw MutationError.invalidPayload }
        next.analyzedProposal = proposal
        commit(next, previous: context, titleUndo: nil)
    }

    /// Computes acceptance before any native title write, without changing state.
    func prepareProposal(expectedRevision: UInt64, proposalID: UUID, tagIDs: [String], acceptTitle: Bool, acceptSummary: Bool) throws -> PreparedChange {
        try verify(expectedRevision)
        guard let proposal = context.analyzedProposal, proposal.id == proposalID else { throw MutationError.proposalNotFound }
        guard Set(tagIDs).count == tagIDs.count,
              tagIDs.allSatisfy({ id in proposal.suggestedTags.contains { $0.id == id } }) else { throw MutationError.invalidPayload }
        let manualDimensions = Set(context.tags.filter { $0.origin == .manual }.map(\.dimension))
        let rejected = Set(context.rejectedAutomaticTagIDs)
        let selected = Set(tagIDs)
        let additions = proposal.suggestedTags.filter { candidate in
            selected.contains(candidate.id) && !manualDimensions.contains(candidate.dimension) && !rejected.contains(candidate.id)
                && !context.tags.contains(where: { existing in existing.id == candidate.id && existing.origin == .manual })
        }
        let replacementDimensions = Set(additions.map(\.dimension))
        var next = context
        next.tags.removeAll { $0.origin == .automatic && replacementDimensions.contains($0.dimension) }
        next.tags.append(contentsOf: additions)
        guard next.tags.count <= 128 else { throw MutationError.invalidPayload }
        if acceptSummary { next.summary = proposal.summary }
        let title = acceptTitle ? proposal.suggestedTitle : nil
        if acceptTitle, title == nil { throw MutationError.invalidPayload }
        return PreparedChange(context: next, previousContext: context, suggestedTitle: title)
    }

    /// Commits the already-validated acceptance after a truthful native title result.
    func commitProposal(_ change: PreparedChange, previousDisplayTitle: String, titleUndo: TitleUndo?) {
        var next = change.context
        if let title = change.suggestedTitle {
            appendAlias(previousDisplayTitle, excluding: title, to: &next)
        }
        commit(next, previous: change.previousContext, titleUndo: titleUndo)
    }

    func pendingUndo(expectedRevision: UInt64) throws -> Undo {
        try verify(expectedRevision)
        guard let undo else { throw MutationError.undoUnavailable }
        return undo
    }

    /// The caller first restores any still-owned title through the native setter.
    func commitUndo(_ previous: Undo, revision: UInt64) {
        var next = previous.context
        next.revision = revision + 1
        next.canUndo = false
        undo = nil
        context = next
        notifyChanged()
    }

    private func verify(_ expectedRevision: UInt64) throws {
        guard context.revision == expectedRevision else { throw MutationError.revisionConflict }
        guard expectedRevision < UInt64.max else { throw MutationError.revisionExhausted }
    }

    private func commit(_ value: CmuxSidebarWorkspaceContext, previous: CmuxSidebarWorkspaceContext, titleUndo: TitleUndo?) {
        var next = value
        next.revision = previous.revision + 1
        next.canUndo = true
        var restorable = previous
        restorable.canUndo = false
        undo = Undo(context: restorable, title: titleUndo)
        context = next
        notifyChanged()
    }

    private func appendAlias(_ previous: String, excluding current: String, to context: inout CmuxSidebarWorkspaceContext) {
        let previous = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previous.isEmpty, previous != current, previous.count <= 512 else { return }
        context.aliases.removeAll { $0 == previous || $0 == current }
        context.aliases.append(previous)
        if context.aliases.count > 32 { context.aliases.removeFirst(context.aliases.count - 32) }
    }

    private func normalizedTag(_ input: CmuxSidebarContextTag) throws -> CmuxSidebarContextTag {
        try validateID(input.id)
        guard let label = try normalizedText(input.label, limit: 128),
              let dimension = try normalizedText(input.dimension, limit: 64),
              let source = try normalizedText(input.source, limit: 128) else { throw MutationError.invalidPayload }
        return CmuxSidebarContextTag(id: input.id, label: label, dimension: dimension, origin: input.origin, source: source)
    }

    private func normalizedProposal(_ input: CmuxSidebarWorkspaceContextProposal) throws -> CmuxSidebarWorkspaceContextProposal {
        guard input.suggestedTags.count <= 128,
              input.conversationIDs.count <= 256,
              Set(input.conversationIDs).count == input.conversationIDs.count,
              input.analyzedAt.timeIntervalSince1970.isFinite,
              let source = try normalizedText(input.source, limit: 128),
              let fingerprint = try normalizedText(input.sourceFingerprint, limit: 256) else { throw MutationError.invalidPayload }
        for id in input.conversationIDs { try validateID(id) }
        var proposal = input
        proposal.source = source
        proposal.sourceFingerprint = fingerprint
        proposal.suggestedTitle = try normalizedText(input.suggestedTitle, limit: 512)
        proposal.summary = try normalizedText(input.summary, limit: 2_000)
        proposal.suggestedTags = try input.suggestedTags.map {
            var tag = try normalizedTag($0)
            tag.origin = .automatic
            tag.source = source
            return tag
        }
        guard Set(proposal.suggestedTags.map(\.id)).count == proposal.suggestedTags.count else { throw MutationError.invalidPayload }
        return proposal
    }

    private func rejectionIDs(_ ids: [String]) throws -> [String] {
        for id in ids { try validateID(id) }
        let unique = Set(ids).sorted()
        guard unique.count <= 512 else { throw MutationError.invalidPayload }
        return unique
    }

    private func validateID(_ id: String) throws {
        guard !id.isEmpty, id.count <= 256, id == id.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw MutationError.invalidPayload }
    }

    private func normalizedText(_ value: String?, limit: Int) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= limit else { throw MutationError.invalidPayload }
        return trimmed.isEmpty ? nil : trimmed
    }

    private func notifyChanged() {
        var terminated: [UUID] = []
        for (id, continuation) in observers {
            if case .terminated = continuation.yield(()) { terminated.append(id) }
        }
        for id in terminated { observers[id] = nil }
    }
}
