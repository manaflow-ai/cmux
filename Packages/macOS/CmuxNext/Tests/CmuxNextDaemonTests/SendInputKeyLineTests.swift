import CmuxNextCompat
import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// HOT PATH AUDIT input (terminal-key, AUDIT.md section 4): every key typed into a daemon terminal becomes one
/// `send` line (`TerminalAttachment.enqueueInput`). The line is the same bytes the request encoder writes, so every
/// daemon reads it as before; making it allocates the line and nothing else (no `JSONEncoder` per key).
struct SendInputKeyLineTests {
    /// The line equals `WireCoding.encodeRequest` byte for byte: every byte value, short and long chunks, with and
    /// without a flow, small and large ids and surfaces.
    @Test func theKeyLineIsTheEncodedRequest() throws {
        var chunks: [Data] = (0...255).map { Data([UInt8($0)]) }
        chunks += [Data("\u{1b}[A".utf8), Data("é".utf8), Data("ab".utf8), Data("abc".utf8), Data((0..<200).map { UInt8($0 % 256) })]
        let flows: [UInt64?] = [nil, 0, 7, (4242 << 32) | 7, .max]
        let ids: [UInt64] = [0, 1, 9, 10, 4_294_967_296, .max]
        let surfaces: [UInt64] = [0, 7, 1_000_000_007, .max]
        for (index, chunk) in chunks.enumerated() {
            let flow = flows[index % flows.count], id = ids[index % ids.count]
            let surface = SurfaceID(rawValue: surfaces[index % surfaces.count])
            let line = SendInputRequest.keyLine(surface: surface, bytes: chunk, flow: flow, id: id)
            let encoded = try WireCoding.encodeRequest(SendInputRequest(surface: surface, bytes: chunk, flow: flow), id: id)
            #expect(line == encoded, "chunk \(index): \(String(decoding: line, as: UTF8.self)) vs \(String(decoding: encoded, as: UTF8.self))")
        }
    }

    /// One key's line costs at most the line's own storage (a `Data` object and its bytes; 3 leaves room for one
    /// more on another libmalloc), however many keys.
    /// Before: a new `JSONEncoder`, its storage and containers, the snake-case key names, the base64 String and a
    /// verbatim-fields cast, per key.
    @Test func aKeyLineAllocatesOnlyTheLine() {
        let key = Data("a".utf8)
        let arrow = Data("\u{1b}[A".utf8)
        // Warm up: the first call may load conformances and caches once per process.
        _ = SendInputRequest.keyLine(surface: 7, bytes: key, flow: 1, id: 1)
        guard let control = KeyLineMallocProbe.allocations({
            let block = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 16)
            block.deallocate()
        }), control > 0 else {
            // No malloc_logger hook in this libmalloc: nothing to count with.
            return
        }
        let keys = 100
        var sink = 0
        let counted = KeyLineMallocProbe.allocations {
            for index in 0..<keys {
                let line = SendInputRequest.keyLine(surface: 7, bytes: index.isMultiple(of: 2) ? key : arrow,
                                                         flow: UInt64(index), id: UInt64(index))
                sink &+= line.count
            }
        } ?? 0
        #expect(sink > 0)
        let perKey = Double(counted) / Double(keys)
        #expect(perKey <= 3, "allocations per key line: \(perKey) (\(counted) for \(keys) keys)")
    }
}

// MARK: Counting the calling thread's allocations (as AgentCursorVisibilityResolveBench counts)

/// libmalloc's allocation hook type (`malloc_logger_t`): type flags, three arguments, the result, frames to skip.
private typealias KeyLineMallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

/// The hook's state: the C hook captures nothing, so it reads these.
nonisolated private struct KeyLineMallocTally {
    /// The mach port of the thread being counted; 0 (`MACH_PORT_NULL`) while none is.
    static let thread = Atomic<UInt32>(0)
    /// Allocations that thread made since counting began.
    static let allocations = Atomic<Int>(0)
}

/// Counts the counted thread's allocations (and reallocations); allocates nothing itself.
nonisolated private func tallyKeyLineMalloc(type: UInt32, arg1: UInt, arg2: UInt, arg3: UInt, result: UInt, skip: UInt32) {
    let allocate: UInt32 = 2  // MALLOC_LOG_TYPE_ALLOCATE
    guard type & allocate != 0, pthread_mach_thread_np(pthread_self()) == KeyLineMallocTally.thread.load(ordering: .relaxed) else { return }
    _ = KeyLineMallocTally.allocations.add(1, ordering: .relaxed)
}

/// How many heap allocations the calling thread makes in `body`; nil when libmalloc exports no hook.
nonisolated private struct KeyLineMallocProbe {
    static func allocations(_ body: () -> Void) -> Int? {
        // RTLD_DEFAULT, a C macro Swift does not import.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        let hook = symbol.assumingMemoryBound(to: KeyLineMallocLogger?.self)
        KeyLineMallocTally.allocations.store(0, ordering: .relaxed)
        KeyLineMallocTally.thread.store(pthread_mach_thread_np(pthread_self()), ordering: .relaxed)
        let previous = hook.pointee
        hook.pointee = tallyKeyLineMalloc
        body()
        hook.pointee = previous
        KeyLineMallocTally.thread.store(0, ordering: .relaxed)
        return KeyLineMallocTally.allocations.load(ordering: .relaxed)
    }
}
