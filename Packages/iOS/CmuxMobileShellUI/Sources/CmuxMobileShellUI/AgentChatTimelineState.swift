import CmuxAgentChat

/// The value state of one mobile agent conversation.
///
/// History pulls and live pushes both pass through this reducer. Keeping the
/// merge rules here prevents a reconnect, a duplicated push, or a reset from
/// being observable as duplicate rows in the SwiftUI timeline.
struct AgentChatTimelineState: Equatable {
    var descriptor: ChatSessionDescriptor
    var messages: [ChatMessage] = []
    var terminalBlocks: [TerminalCommandBlock] = []
    var streamingProse: ChatMessage?
    var hasMoreHistory = false
    var isLoadingHistory = false
    var lastError: String?

    init(descriptor: ChatSessionDescriptor) {
        self.descriptor = descriptor
    }

    mutating func mergeHistory(_ page: ChatHistoryPage, prepending: Bool) {
        let incoming = page.messages
        if prepending {
            upsert(incoming)
        } else {
            upsert(incoming)
        }
        if let blocks = page.terminalBlocks {
            upsert(blocks)
        }
        hasMoreHistory = page.hasMore
        isLoadingHistory = false
        lastError = nil
    }

    mutating func apply(_ event: ChatSessionEvent) {
        switch event {
        case .appended(let incoming):
            upsert(incoming)
            if incoming.contains(where: { $0.role == .agent && isProse($0.kind) }) {
                streamingProse = nil
            }
        case .updated(let incoming):
            upsert(incoming)
        case .stateChanged(let state):
            descriptor = descriptor.withState(state)
        case .descriptorChanged(let next):
            guard next.version >= descriptor.version else { return }
            descriptor = next
        case .sessionRemoved:
            descriptor = descriptor.withState(.ended)
        case .terminalBlocks(let blocks):
            upsert(blocks)
        case .streamingProse(let message):
            streamingProse = message
        case .reset:
            messages.removeAll(keepingCapacity: true)
            terminalBlocks.removeAll(keepingCapacity: true)
            streamingProse = nil
            hasMoreHistory = false
        case .unknown:
            break
        }
    }

    mutating func applyError(_ error: any Error) {
        isLoadingHistory = false
        lastError = error.localizedDescription
    }

    private mutating func upsert(_ incoming: [ChatMessage]) {
        guard !incoming.isEmpty else { return }
        var byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for message in incoming {
            byID[message.id] = message
        }
        messages = byID.values.sorted {
            if $0.seq != $1.seq { return $0.seq < $1.seq }
            return $0.id < $1.id
        }
    }

    private mutating func upsert(_ incoming: [TerminalCommandBlock]) {
        guard !incoming.isEmpty else { return }
        var byID = Dictionary(uniqueKeysWithValues: terminalBlocks.map { ($0.id, $0) })
        for block in incoming {
            byID[block.id] = block
        }
        terminalBlocks = byID.values.sorted { $0.id < $1.id }
    }

    private func isProse(_ kind: ChatMessageKind) -> Bool {
        if case .prose = kind { return true }
        return false
    }
}
