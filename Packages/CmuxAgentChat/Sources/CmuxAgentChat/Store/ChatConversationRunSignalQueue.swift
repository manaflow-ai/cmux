import Foundation

enum ChatConversationRunSignal: Sendable {
    case event(ChatSessionEvent)
    case retryPendingTranscript
    case streamEnded
    case overflowed
}

actor ChatConversationRunSignalQueue {
    private let limit: Int
    private var buffered: [ChatConversationRunSignal] = []
    private var waiters: [CheckedContinuation<ChatConversationRunSignal?, Never>] = []
    private var isClosed = false
    private var overflowQueued = false

    init(limit: Int) {
        self.limit = max(2, limit)
    }

    func enqueue(_ signal: ChatConversationRunSignal) {
        guard !isClosed else { return }
        if let waiter = waiters.popLast() {
            waiter.resume(returning: signal)
            return
        }
        if signal.isReplayableByHistory, overflowQueued {
            return
        }
        if buffered.count >= limit {
            compactForOverflow(including: signal)
            return
        }
        buffered.append(signal)
    }

    func next() async -> ChatConversationRunSignal? {
        if !buffered.isEmpty {
            let signal = buffered.removeFirst()
            if case .overflowed = signal {
                overflowQueued = false
            }
            return signal
        }
        guard !isClosed else { return nil }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func close() {
        isClosed = true
        buffered.removeAll()
        overflowQueued = false
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
        waiters.removeAll()
    }

    private func compactForOverflow(including incoming: ChatConversationRunSignal) {
        var latestState: ChatConversationRunSignal?
        var latestDescriptor: ChatConversationRunSignal?
        var latestTerminalBlocks: ChatConversationRunSignal?
        var latestReset: ChatConversationRunSignal?
        var latestUnknown: ChatConversationRunSignal?
        var latestRetry: ChatConversationRunSignal?
        var sawStreamEnded = false

        for signal in buffered + [incoming] {
            switch signal {
            case .event(let event):
                switch event {
                case .appended, .updated:
                    break
                case .stateChanged:
                    latestState = signal
                case .descriptorChanged:
                    latestDescriptor = signal
                case .terminalBlocks:
                    latestTerminalBlocks = signal
                case .reset:
                    latestReset = signal
                case .unknown:
                    latestUnknown = signal
                }
            case .retryPendingTranscript:
                latestRetry = signal
            case .streamEnded:
                sawStreamEnded = true
            case .overflowed:
                overflowQueued = true
            }
        }

        var compacted: [ChatConversationRunSignal] = []
        let snapshotLimit = max(0, limit - 1 - (sawStreamEnded ? 1 : 0))
        for signal in [latestReset, latestDescriptor, latestState, latestTerminalBlocks, latestUnknown] {
            guard compacted.count < snapshotLimit, let signal else { continue }
            compacted.append(signal)
        }
        compacted.append(.overflowed)
        let retryLimit = limit - (sawStreamEnded ? 1 : 0)
        if let latestRetry, compacted.count < retryLimit {
            compacted.append(latestRetry)
        }
        if sawStreamEnded {
            compacted.append(.streamEnded)
        }
        buffered = Array(compacted.prefix(limit))
        overflowQueued = true
    }
}

private extension ChatConversationRunSignal {
    var isReplayableByHistory: Bool {
        guard case .event(let event) = self else { return false }
        switch event {
        case .appended, .updated:
            return true
        case .stateChanged, .descriptorChanged, .terminalBlocks, .reset, .unknown:
            return false
        }
    }
}
