import CmuxNextCompat

/// The `task.blocking_call` intervals of the process's checked blocking calls (p02-threads task 124,
/// plans/cmux-next/trace.md "Blocking calls and lane jobs"). A runtime that routes them (``shared``) hands
/// ``CmuxNextCompat/BlockingTraceHook`` its sink while its `task` category records, so a call with the category off
/// pays the hook's one acquiring load. Chrome writes the same interval from `ScopedBlockingCall`
/// (base/threading/scoped_blocking_call.cc).
extension TraceRuntime {
    /// The name of one checked blocking call's slice (category `task`, interned): begin arg0 the kind's
    /// ``CmuxNextCompat/BlockingKind/traceCode`` in bits 0-7 and the call's `#line` above them, begin arg1 the
    /// FNV-1a 64 hash of its `#fileID`; the end has no arguments.
    static let blockingCallText: StaticString = "task.blocking_call"

    /// Makes this runtime's blocking-call sink; `init` calls it once for a runtime that routes blocking calls.
    func installBlockingCallSink() {
        let name = InternedName(Self.blockingCallText, categoryBit: TraceCategories.taskBit)
        let sink = BlockingTraceSink(began: { [self] kind, fileID, line in
            write(name, phase: .begin, arg0: Self.blockingCallSite(kind, line: line), arg1: Self.fileIDHash(fileID))
        }, ended: { [self] _ in
            writeEnd(name, phase: .end)
        })
        blockingSinkAddress.store(UInt64(UInt(bitPattern: Unmanaged.passRetained(sink).toOpaque())),
                                  ordering: .sequentiallyConsistent)
    }

    /// Points the blocking-call hook at this runtime's sink while `mask` holds `task`, and away from it while it
    /// does not. Every category change publishes through here; a runtime that does not route them does nothing.
    func mirrorBlockingCalls(_ mask: UInt64) {
        let address = blockingSinkAddress.load(ordering: .sequentiallyConsistent)
        guard address != 0, let pointer = UnsafeRawPointer(bitPattern: UInt(address)) else { return }
        let sink = Unmanaged<BlockingTraceSink>.fromOpaque(pointer).takeUnretainedValue()
        BlockingTraceHook.update(sink, recording: TraceCategories(rawValue: mask).contains(.task))
    }

    /// A `task.blocking_call` begin's arg0: the kind's code in bits 0-7, the line above them.
    static func blockingCallSite(_ kind: BlockingKind, line: UInt) -> UInt64 {
        UInt64(kind.traceCode) | UInt64(line) << 8
    }

    /// FNV-1a 64 of `fileID`'s UTF-8 bytes (a `task.blocking_call` begin's arg1): a reader hashes each source file's
    /// `Module/File.swift` the same way to name the site.
    static func fileIDHash(_ fileID: StaticString) -> UInt64 {
        fileID.withUTF8Buffer { bytes in
            bytes.reduce(0xcbf2_9ce4_8422_2325 as UInt64) { hash, byte in (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        }
    }
}
