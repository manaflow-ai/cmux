import CmuxNextDaemon
import Foundation

/// One phone's live view of one terminal: a dedicated daemon byte attach,
/// renumbered into the shipped phone's byte sequence space.
///
/// `seq` is the byte offset where a chunk starts. A replay answers with the
/// offset where live bytes continue; every stream for a surface continues
/// the previous one's numbering, so the phone never mistakes new bytes for a
/// duplicate of old ones.
actor MobileCompatTerminalStream {
    typealias Emit = @Sendable (_ surfaceID: String, _ seq: UInt64, _ bytes: Data) async -> Void

    let surfaceID: String
    private let channel: any MobileCompatTerminalChannel
    private var replay: TerminalReplay?
    /// Offset where live bytes continue after `replay`.
    private var replaySeq: UInt64 = 0
    private var replayWaiters: [CheckedContinuation<TerminalReplay?, Never>] = []
    private(set) var nextSeq: UInt64
    private var pump: Task<Void, Never>?
    private var ended = false

    init(surfaceID: String, channel: any MobileCompatTerminalChannel, startSeq: UInt64) {
        self.surfaceID = surfaceID
        self.channel = channel
        nextSeq = startSeq
    }

    /// Starts forwarding. `emit` receives live output after the initial replay.
    func start(emit: @escaping Emit) {
        guard pump == nil else { return }
        let events = channel.events
        pump = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event, emit: emit)
            }
            await self?.finish()
        }
    }

    /// The attach's initial replay and the offset live bytes continue from.
    /// Nil when the attachment closed before its snapshot.
    func initialReplay() async -> (replay: TerminalReplay, seq: UInt64)? {
        if let replay { return (replay, replaySeq) }
        if ended { return nil }
        guard let replay = await withCheckedContinuation({ replayWaiters.append($0) }) else { return nil }
        return (replay, replaySeq)
    }

    func resize(cols: Int, rows: Int) async {
        await channel.resize(cols: cols, rows: rows)
        await channel.claimGeometry()
    }

    func stop() async {
        pump?.cancel()
        await channel.detach()
        finish()
    }

    var isEnded: Bool { ended }

    private func handle(_ event: TerminalChannelEvent, emit: Emit) async {
        switch event {
        case .replay(let snapshot):
            guard replay == nil else { return }
            replay = snapshot
            replaySeq = nextSeq
            resumeWaiters(with: snapshot)
        case .output(let data, _):
            guard replay != nil, !data.isEmpty else { return }
            let seq = nextSeq
            nextSeq += UInt64(data.count)
            await emit(surfaceID, seq, data)
        case .resized(let snapshot):
            replay = snapshot
            let bytes = MobileCompatReplayBytes.replacement(snapshot)
            let seq = nextSeq
            nextSeq += UInt64(bytes.count)
            await emit(surfaceID, seq, bytes)
        case .colorsChanged, .scrollChanged:
            break
        case .closed:
            finish()
        }
    }

    private func finish() {
        ended = true
        resumeWaiters(with: nil)
    }

    private func resumeWaiters(with replay: TerminalReplay?) {
        let waiters = replayWaiters
        replayWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: replay) }
    }
}
