import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Observation

/// Main-actor state for one optimistic native todo surface.
@MainActor
@Observable
final class TodoSurfaceModel {
    private let mutate: @MainActor (MobileTodoMutation) async throws -> Void
    private var deferredAuthoritativeSnapshot: MobileTodoSnapshot?
    private(set) var snapshot: MobileTodoSnapshot
    private(set) var pendingRequestID: UUID?
    private(set) var showsMutationError = false

    init(
        snapshot: MobileTodoSnapshot,
        mutate: @escaping @MainActor (MobileTodoMutation) async throws -> Void
    ) {
        self.snapshot = snapshot
        self.mutate = mutate
    }

    var isMutationPending: Bool { pendingRequestID != nil }

    /// Reconciles a live host snapshot, deferring it while an optimistic request is in flight.
    func reconcile(_ authoritative: MobileTodoSnapshot) {
        if pendingRequestID != nil {
            deferredAuthoritativeSnapshot = authoritative
        } else {
            snapshot = authoritative
        }
    }

    /// Applies one optimistic mutation and rolls it back if the Mac rejects it.
    @discardableResult
    func perform(_ mutation: MobileTodoMutation) async -> Bool {
        guard pendingRequestID == nil,
              let optimistic = applying(mutation, to: snapshot) else { return false }
        let requestID = UUID()
        let previous = snapshot
        pendingRequestID = requestID
        deferredAuthoritativeSnapshot = nil
        showsMutationError = false
        snapshot = optimistic
        do {
            try await mutate(mutation)
            guard pendingRequestID == requestID else { return true }
            if let authoritative = deferredAuthoritativeSnapshot {
                snapshot = authoritative
            }
            pendingRequestID = nil
            deferredAuthoritativeSnapshot = nil
            return true
        } catch {
            guard pendingRequestID == requestID else { return false }
            snapshot = deferredAuthoritativeSnapshot ?? previous
            pendingRequestID = nil
            deferredAuthoritativeSnapshot = nil
            showsMutationError = true
            return false
        }
    }

    func dismissMutationError() {
        showsMutationError = false
    }

    private func applying(
        _ mutation: MobileTodoMutation,
        to snapshot: MobileTodoSnapshot
    ) -> MobileTodoSnapshot? {
        var status = snapshot.status
        var statusHidden = snapshot.statusHidden
        var items = snapshot.items
        switch mutation {
        case .add(let rawText):
            guard items.count < MobileTodoSnapshot.maxItems,
                  let text = normalizedText(rawText) else { return nil }
            items.append(MobileTodoItem(
                id: UUID().uuidString,
                text: text,
                state: .pending,
                origin: .user
            ))
        case .setState(let itemID, let nextState):
            guard let index = items.firstIndex(where: { $0.id == itemID }) else { return nil }
            let previousItem = items[index]
            let wasCompleted = previousItem.state == .completed
            let updated = MobileTodoItem(
                id: previousItem.id,
                text: previousItem.text,
                state: nextState,
                origin: previousItem.origin
            )
            items[index] = updated
            if wasCompleted != (nextState == .completed) {
                items.remove(at: index)
                let firstCompleted = items.firstIndex(where: { $0.state == .completed }) ?? items.endIndex
                if nextState == .completed {
                    items.append(updated)
                } else {
                    items.insert(updated, at: firstCompleted)
                }
            }
        case .edit(let itemID, let rawText):
            guard let index = items.firstIndex(where: { $0.id == itemID }),
                  let text = normalizedText(rawText) else { return nil }
            let item = items[index]
            items[index] = MobileTodoItem(id: item.id, text: text, state: item.state, origin: item.origin)
        case .move(let itemID, let toIndex):
            guard let index = items.firstIndex(where: { $0.id == itemID }) else { return nil }
            let item = items.remove(at: index)
            let incomplete = items.filter { $0.state != .completed }
            let completed = items.filter { $0.state == .completed }
            if item.state == .completed {
                let localIndex = min(max(toIndex - incomplete.count, 0), completed.count)
                var reordered = completed
                reordered.insert(item, at: localIndex)
                items = incomplete + reordered
            } else {
                let localIndex = min(max(toIndex, 0), incomplete.count)
                var reordered = incomplete
                reordered.insert(item, at: localIndex)
                items = reordered + completed
            }
        case .remove(let itemID):
            guard let index = items.firstIndex(where: { $0.id == itemID }) else { return nil }
            items.remove(at: index)
        case .openOnMac:
            break
        case .setStatus(let nextStatus):
            status = nextStatus ?? status
            statusHidden = false
        case .cycleStatus:
            status = status.next
            statusHidden = false
        }
        return MobileTodoSnapshot(status: status, statusHidden: statusHidden, items: items)
    }

    private func normalizedText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(MobileTodoItem.maxTextLength))
    }
}
