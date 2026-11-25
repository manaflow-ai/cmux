import CmuxNextCompat
import CmuxNextWakeups
import CoreGraphics
import Foundation

/// The keeper's frame writes as deltas (FILES QUEUE, Leo's NIGHTLY 2026-11-21: the serial `files.bestEffort` lane was
/// busy 66% of a 3 s sample, all in the keeper's PNG encode, and every other best-effort file job of the app waited
/// behind it). Before, every save encoded and wrote its frame on the files lane: a terminal switched away lost its file
/// and was encoded again when shown, with the same pixels. Now:
///
/// - **No re-encode of an unchanged frame.** A save hashes its pixels (``digest(_:)``, 22 ms for Leo's 4642 x 2576 px
///   frames, against 46-57 ms for their PNG); the same pixels at the same scale as the file on disk write nothing.
/// - **A switch away parks the file, a switch back restores it.** A hidden terminal's file is renamed to
///   `<key>@<scale>x.jpg.parked` (no launch reads it: ``TerminalLaunchFrames/owner(of:)`` takes it for no frame), and
///   renamed back when the terminal shows the same pixels again: one rename each way, no encode.
/// - **Latest wins per terminal.** A save while the key's last one waits replaces it: at most one frame per terminal is
///   held, however busy the lanes are.
/// - **The encode runs on the CPU lane, one at a time**, not on the files lane: the files lane does only renames and
///   writes, so other file work at the same priority (`LaunchRecordWriter`, `LaunchTimesFile`, `AppHealthFeeds`) never
///   waits for a PNG, and the keeper holds at most one CPU slot however many terminals change (terminals take turns,
///   oldest first).
///
/// Ordering: every file operation of a key runs on the files lane (serial per priority), in the order the keeper asked;
/// a hide or close bumps the key's epoch first, so a write encoded before it lands nothing.
nonisolated final class TerminalLaunchFrameWriter: Sendable {
    /// What the writer did so far (tests, the keeper bench).
    struct Stats: Sendable, Equatable {
        /// Frames encoded (changed pixels).
        var encodes = 0
        /// Saves whose pixels were the file's already: nothing encoded or written.
        var unchanged = 0
        /// Saves of a terminal shown again with the pixels it was hidden with: its parked file renamed back.
        var restored = 0
        /// Saves replaced by a newer one of the same terminal before the lane took them.
        var coalesced = 0
    }

    /// A frame's pixels at a scale: what a file holds.
    private struct Saved: Equatable {
        let digest: Int
        let scale: Int
    }

    private struct Pending: Sendable {
        let frame: CGImage
        let scale: Int
        let keeping: Set<String>?
        let epoch: UInt64
        let written: (@Sendable (String) -> Void)?
    }

    private struct State {
        /// The latest frame of each key not yet taken by the CPU lane.
        var pending: [String: Pending] = [:]
        /// Keys with a save between its encode and its file operation: one at a time per key, so its writes land in
        /// order; a save meanwhile waits in ``pending`` and runs when it ends.
        var busy: Set<String> = []
        /// Keys with a pending save and none in flight, oldest first: the next encode takes the first.
        var ready: [String] = []
        /// Whether an encode is on the CPU lane (one at a time).
        var encoding = false
        /// What each key's live file holds.
        var onDisk: [String: Saved] = [:]
        /// What each key's parked file holds (hidden terminals).
        var parked: [String: Saved] = [:]
        /// Bumped by each hide or close: work of an older epoch lands nothing.
        var epochs: [String: UInt64] = [:]
        var stats = Stats()
    }

    private let state = Mutex(State())
    private let directory: URL
    private let work: BackgroundWork
    private let stillWanted: @Sendable () -> Bool
    /// The writer's jobs on each lane and their thread CPU time (the keeper bench).
    let filesLane = LaneCostMeter()
    let cpuLane = LaneCostMeter()

    /// `stillWanted` is asked before every file operation (false once the quit saves every frame itself).
    init(directory: URL, work: BackgroundWork, stillWanted: @escaping @Sendable () -> Bool) {
        self.directory = directory
        self.work = work
        self.stillWanted = stillWanted
    }

    var stats: Stats { state.withLock { $0.stats } }

    /// Saves `frame` as `key`'s file at `scale` (with `keeping`, also drops the files of keys not in it). Returns at once.
    func save(_ key: String, frame: CGImage, scale: Int, keeping: Set<String>?, written: (@Sendable (String) -> Void)?) {
        state.withLock { state in
            if state.pending[key] != nil { state.stats.coalesced += 1 }
            state.pending[key] = Pending(frame: frame, scale: scale, keeping: keeping, epoch: state.epochs[key, default: 0],
                                         written: written)
            Self.enqueue(key, in: &state)
        }
        pump()
    }

    /// Marks `key` ready unless a save of it is in flight or it is ready already.
    private static func enqueue(_ key: String, in state: inout State) {
        guard state.pending[key] != nil, !state.busy.contains(key), !state.ready.contains(key) else { return }
        state.ready.append(key)
    }

    /// Starts the oldest ready key's encode when none runs.
    private func pump() {
        let next = state.withLock { state -> String? in
            guard !state.encoding, !state.ready.isEmpty else { return nil }
            let key = state.ready.removeFirst()
            state.encoding = true
            state.busy.insert(key)
            return key
        }
        guard let next else { return }
        work.post(.bestEffort, mayBlock: .cpu) { [self] in
            cpuLane.measure { encode(next) }
            state.withLock { $0.encoding = false }
            pump()
        }
    }

    /// The key's save ended (written, unchanged or dropped): a newer one of it waits for its turn again.
    private func finish(_ key: String) {
        state.withLock { state in
            state.busy.remove(key)
            Self.enqueue(key, in: &state)
        }
        pump()
    }

    /// The terminal is hidden: its file is parked (not read at launch), to be restored if it shows the same pixels again.
    func park(_ key: String, written: (@Sendable (String) -> Void)?) {
        let epoch = bump(key)
        let directory = directory
        work.post(.bestEffort, mayBlock: .files) { [self] in filesLane.measure {
            guard stillWanted(), current(key, epoch) else { return }
            let saved = state.withLock { $0.onDisk.removeValue(forKey: key) }
            let parked = TerminalLaunchFrames.park(key, scale: saved?.scale, in: directory)
            state.withLock { $0.parked[key] = parked ? saved : nil }
            written?(key)
        } }
    }

    /// The terminal is closed: its files go, parked or not.
    func forget(_ key: String, written: (@Sendable (String) -> Void)?) {
        let epoch = bump(key)
        let directory = directory
        work.post(.bestEffort, mayBlock: .files) { [self] in filesLane.measure {
            guard stillWanted(), current(key, epoch) else { return }
            state.withLock { _ = $0.onDisk.removeValue(forKey: key); _ = $0.parked.removeValue(forKey: key) }
            TerminalLaunchFrames.removeAll(of: key, in: directory)
            written?(key)
        } }
    }

    private func bump(_ key: String) -> UInt64 {
        state.withLock { state in
            state.pending[key] = nil
            state.ready.removeAll { $0 == key }
            state.epochs[key, default: 0] += 1
            return state.epochs[key, default: 0]
        }
    }

    private func current(_ key: String, _ epoch: UInt64) -> Bool { state.withLock { $0.epochs[key, default: 0] == epoch } }

    /// CPU lane: the key's latest frame, hashed; encoded only when its pixels are not on disk, live or parked. What a
    /// frame with known pixels does is decided again on the files lane, where the key's file operations run in order.
    private func encode(_ key: String) {
        guard stillWanted(), let job = state.withLock({ $0.pending.removeValue(forKey: key) }) else {
            state.withLock { _ = $0.busy.remove(key) }
            return
        }
        // Its turn came: from here its file step ends the save (finish), on the files lane.
        let saved = Saved(digest: Self.digest(job.frame), scale: job.scale)
        let known = state.withLock { $0.onDisk[key] == saved || $0.parked[key] == saved }
        guard current(key, job.epoch) else { return finish(key) }
        let data = known ? nil : TerminalLaunchFrames.encoded(job.frame)
        if !known { state.withLock { $0.stats.encodes += 1 } }
        work.post(.bestEffort, mayBlock: .files) { [self] in filesLane.measure { writeStep(key, job, saved, known, data) } }
    }

    /// Files lane: the file operation of one save, in the key's order.
    private func writeStep(_ key: String, _ job: Pending, _ saved: Saved, _ known: Bool, _ data: Data?) {
        defer { finish(key) }
        guard stillWanted(), current(key, job.epoch) else { return }
        if known {
            enum Known { case live, parked, gone }
            let now = state.withLock { state -> Known in
                state.onDisk[key] == saved ? .live : state.parked[key] == saved ? .parked : .gone
            }
            let restored = now == .parked && TerminalLaunchFrames.restore(key, scale: job.scale, in: directory,
                                                                            keeping: job.keeping)
            if now == .live {
                state.withLock { $0.stats.unchanged += 1 }
                if let keeping = job.keeping { TerminalLaunchFrames.prune(directory, keeping: keeping, except: key) }
            } else if restored {
                state.withLock { $0.onDisk[key] = saved; $0.parked[key] = nil; $0.stats.restored += 1 }
            } else {
                // Its file went meanwhile (a hide, a prune): encode after all, unless a newer save of the key waits
                // already (finish runs it).
                state.withLock { state in
                    state.parked[key] = nil
                    if state.pending[key] == nil { state.pending[key] = job }
                }
                return
            }
        } else {
            // A frame that does not encode within the read's cap writes nothing; the other keys' cleanup still runs.
            let wrote = TerminalLaunchFrames.writeOne(data: data, key: key, scale: job.scale, to: directory,
                                                      keeping: job.keeping, stillWanted: stillWanted)
            state.withLock { state in
                state.onDisk[key] = wrote ? saved : nil
                if wrote { state.parked[key] = nil }
            }
        }
        job.written?(key)
    }

    /// A hash of the frame's pixels and layout (the standard library's `Hasher`, built optimized whatever the app's own
    /// build: 22 ms for a 4642 x 2576 px frame, 75 ms at background QoS, on an M5 Ultra). Two frames with the same digest are taken for the
    /// same picture; a false "changed" costs one encode, never a wrong frame on disk. Per process (`Hasher` is seeded
    /// per launch), as the writer's own records are.
    static func digest(_ frame: CGImage) -> Int {
        var hasher = Hasher()
        for value in [frame.width, frame.height, frame.bytesPerRow, frame.bitsPerPixel, Int(frame.bitmapInfo.rawValue)] {
            hasher.combine(value)
        }
        guard let data = frame.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            // No pixels to read: a hash no other frame has, so it is always encoded.
            hasher.combine(UInt64.random(in: .min ... .max))
            return hasher.finalize()
        }
        hasher.combine(bytes: UnsafeRawBufferPointer(start: bytes, count: CFDataGetLength(data)))
        return hasher.finalize()
    }
}
