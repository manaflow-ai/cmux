public import CmuxHomeCore
public import CmuxNextHome
import Foundation
public import Observation

/// Home's message requests (plans/cmux-next/home-messaging-invites/DESIGN.md 2.3): the list
/// the sidebar's Message Requests button counts and its sheet shows, and the one path for
/// Accept, Decline and Block. An answer takes the request off at once and puts it back when
/// the owner refuses it.
@MainActor @Observable
public final class HomeMessageRequests {
    public private(set) var items: [HomeMessageRequest] = []
    @ObservationIgnored private let source: any HomeMessageRequestSource
    // task-owner: the one list read in flight; ends with its reply (a reload asked meanwhile runs once more)
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var again = false
    /// Answers sent and not answered yet: a list read meanwhile does not show them again.
    @ObservationIgnored private var answering: Set<ConversationID> = []

    public init(source: any HomeMessageRequestSource) {
        self.source = source
    }

    /// Reads the list again; calls while a read runs coalesce into one more read.
    public func refresh() {
        guard reading == nil else {
            again = true
            return
        }
        reading = Task { [weak self] in
            await self?.readLoop()
        }
    }

    /// Reads the list now and returns when it is applied.
    public func reload() async {
        if let reading {
            again = true
            await reading.value
            return
        }
        refresh()
        await reading?.value
    }

    private func readLoop() async {
        // wakeup-allow: each pass awaits one read; it repeats only when refresh() asked again during that read
        repeat {
            again = false
            // A failed read keeps the last list (offline, or no lease yet).
            if let listed = try? await source.messageRequests() {
                items = listed.filter { !answering.contains($0.conversation) }
            }
        } while again
        reading = nil
    }

    /// Accept, Decline or Block one request. Returns whether the owner took it.
    public func answer(_ conversation: ConversationID, _ answer: HomeRequestAnswer) async -> Bool {
        let index = items.firstIndex { $0.conversation == conversation }
        let request = index.map { items.remove(at: $0) }
        answering.insert(conversation)
        defer { answering.remove(conversation) }
        do {
            try await source.answer(conversation, answer)
            return true
        } catch {
            // The owner refused or was not reached: the request shows again where it was.
            if let request, let index, !items.contains(where: { $0.conversation == conversation }) {
                items.insert(request, at: min(index, items.count))
            }
            return false
        }
    }
}
