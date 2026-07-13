import CCEF
import Foundation

// Swift-implemented CEF handler structs (cef_client_t, cef_app_t, ...).
//
// Each handler is allocated as [16-byte header][cef struct]. CEF sees a
// pointer to the cef struct; the header in front carries the atomic reference
// count and an Unmanaged reference to the owning Swift object. The base
// callbacks are fixed non-generic C functions that recover the header with
// pointer arithmetic, so this works for every handler struct type without
// code generation.
//
// Ownership follows the CEF C API contract: structs are created with one
// reference which is transferred to CEF when passed as a function argument.
// Getter callbacks (get_life_span_handler etc.) must add_ref before returning.

private let cefHandlerHeaderSize = 16

private struct CEFHandlerHeader {
    var refCount: Int32
    var padding: Int32
    var object: UnsafeMutableRawPointer?
}

@inline(__always)
private func refCountPointer(_ structPtr: UnsafeMutableRawPointer) -> UnsafeMutablePointer<Int32> {
    (structPtr - cefHandlerHeaderSize).assumingMemoryBound(to: Int32.self)
}

@inline(__always)
private func headerPointer(_ structPtr: UnsafeMutableRawPointer) -> UnsafeMutablePointer<CEFHandlerHeader> {
    (structPtr - cefHandlerHeaderSize).assumingMemoryBound(to: CEFHandlerHeader.self)
}

private func handlerAddRef(_ base: UnsafeMutablePointer<cef_base_ref_counted_t>?) {
    guard let base else { return }
    _ = cefkit_atomic_add(refCountPointer(UnsafeMutableRawPointer(base)), 1)
}

private func handlerRelease(_ base: UnsafeMutablePointer<cef_base_ref_counted_t>?) -> Int32 {
    guard let base else { return 0 }
    let raw = UnsafeMutableRawPointer(base)
    let remaining = cefkit_atomic_add(refCountPointer(raw), -1)
    guard remaining == 0 else { return 0 }
    let header = headerPointer(raw)
    if let object = header.pointee.object {
        Unmanaged<AnyObject>.fromOpaque(object).release()
    }
    (raw - cefHandlerHeaderSize).deallocate()
    return 1
}

private func handlerHasOneRef(_ base: UnsafeMutablePointer<cef_base_ref_counted_t>?) -> Int32 {
    guard let base else { return 0 }
    return cefkit_atomic_load(refCountPointer(UnsafeMutableRawPointer(base))) == 1 ? 1 : 0
}

private func handlerHasAtLeastOneRef(_ base: UnsafeMutablePointer<cef_base_ref_counted_t>?) -> Int32 {
    guard let base else { return 0 }
    return cefkit_atomic_load(refCountPointer(UnsafeMutableRawPointer(base))) >= 1 ? 1 : 0
}

enum CEFHandler {
    /// Allocates a zeroed cef handler struct with its base callbacks wired and
    /// one reference held by the returned pointer. `object` is retained until
    /// the reference count drops to zero.
    static func allocate<T>(_ type: T.Type, object: AnyObject) -> UnsafeMutablePointer<T> {
        let totalSize = cefHandlerHeaderSize + MemoryLayout<T>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: totalSize, alignment: 16)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: totalSize)
        let header = raw.bindMemory(to: CEFHandlerHeader.self, capacity: 1)
        cefkit_atomic_store(raw.assumingMemoryBound(to: Int32.self), 1)
        header.pointee.object = Unmanaged.passRetained(object).toOpaque()
        let structRaw = raw + cefHandlerHeaderSize
        let base = structRaw.bindMemory(to: cef_base_ref_counted_t.self, capacity: 1)
        base.pointee.size = numericCast(MemoryLayout<T>.size)
        base.pointee.add_ref = handlerAddRef
        base.pointee.release = handlerRelease
        base.pointee.has_one_ref = handlerHasOneRef
        base.pointee.has_at_least_one_ref = handlerHasAtLeastOneRef
        return UnsafeMutableRawPointer(structRaw).bindMemory(to: T.self, capacity: 1)
    }

    /// Recovers the Swift object owning a handler struct, from any callback's
    /// `self` argument.
    static func object<O: AnyObject>(_ type: O.Type, from structPtr: UnsafeMutableRawPointer) -> O {
        let header = headerPointer(structPtr)
        return unsafeDowncast(Unmanaged<AnyObject>.fromOpaque(header.pointee.object!).takeUnretainedValue(), to: O.self)
    }

    /// Adds a reference before handing the struct to a caller that assumes
    /// ownership (the getter-callback convention).
    static func retain(_ structPtr: UnsafeMutableRawPointer) {
        _ = cefkit_atomic_add(refCountPointer(structPtr), 1)
    }
}

// MARK: - CEF-owned objects

// Objects CEF hands to us (cef_browser_t, cef_frame_t, ...) start with
// cef_base_ref_counted_t; these helpers drive their reference counts.

@inline(__always)
func cefAddRef(_ raw: UnsafeMutableRawPointer) {
    let base = raw.assumingMemoryBound(to: cef_base_ref_counted_t.self)
    base.pointee.add_ref?(base)
}

@inline(__always)
func cefRelease(_ raw: UnsafeMutableRawPointer) {
    let base = raw.assumingMemoryBound(to: cef_base_ref_counted_t.self)
    _ = base.pointee.release?(base)
}
