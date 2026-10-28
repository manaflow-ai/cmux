import Foundation
import os

/// The C functions that stand in for the shim's `mirror` exports and `cmux_shim_free` in the
/// deferred-event mode: each answers from ``CEFMirrorCache`` on the main thread. Every shim call is
/// the main thread's, as the remote shim asserts; a call elsewhere gets the C zero value and a fault,
/// never Chromium's live answer.
nonisolated enum CEFMirrorExports {
    typealias HostRead = @convention(c) () -> Int32
    typealias TabRead = @convention(c) (Int32) -> Int32
    typealias TabString = @convention(c) (Int32) -> UnsafeMutablePointer<CChar>?
    typealias ActionsString = @convention(c) (Int32, Int32) -> UnsafeMutablePointer<CChar>?
    typealias BoundsRead = @convention(c) (Int32, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?,
                                           UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Int32
    typealias IDsRead = @convention(c) (Int32, UnsafeMutablePointer<Int32>?, Int32) -> Int32
    typealias Free = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    /// The cache the functions read. A C function of the shim's ABI carries no context, so the
    /// process has one, as the remote shim's cache is its dylib's. Every shim over it holds it, and
    /// `CEFMirrorCache.shim(helloNow:)` refuses another while it lives, so each served shim's reads
    /// and frees reach its own cache and source.
    @MainActor static weak var served: CEFMirrorCache?

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef")

    /// The function for a mirror export or `cmux_shim_free`; nil for every other export.
    static func function(named name: String) -> UnsafeMutableRawPointer? {
        // SAFETY: a nonzero address is a C function of the export's type (`functionAddress`), which
        // `CEFShimLibrary.Resolver` casts back to that type.
        unsafe UnsafeMutableRawPointer(bitPattern: functionAddress(named: name))
    }

    // SAFETY (every `unsafe` below): each closure is the C function of its export's type (the `as` cast), and
    // it hands its pointer arguments and results to the C caller as the ABI says (see each function).
    private static func functionAddress(named name: String) -> UInt {
        if name == "cmux_shim_free" { return unsafe address({ unsafe CEFMirrorExports.free($0) } as Free) }
        guard let field = CEFMirrorField.allCases.first(where: { $0.export == name }) else { return 0 }
        return switch field {
        case .forkAPIVersion: address({ CEFMirrorExports.int(CEFMirrorKey(.forkAPIVersion)) } as HostRead)
        case .placeholderSupported: address({ CEFMirrorExports.int(CEFMirrorKey(.placeholderSupported)) } as HostRead)
        case .navigationRestoreSupported: address({ CEFMirrorExports.int(CEFMirrorKey(.navigationRestoreSupported)) } as HostRead)
        case .foreignBrowserCount: address({ CEFMirrorExports.int(CEFMirrorKey(.foreignBrowserCount)) } as HostRead)
        case .liveBrowserCount: address({ CEFMirrorExports.int(CEFMirrorKey(.liveBrowserCount)) } as HostRead)
        case .windowCount: address({ CEFMirrorExports.int(CEFMirrorKey(.windowCount)) } as HostRead)
        case .passwordImportAvailable: address({ CEFMirrorExports.int(CEFMirrorKey(.passwordImportAvailable)) } as HostRead)
        case .passwordReplaceAvailable: address({ CEFMirrorExports.int(CEFMirrorKey(.passwordReplaceAvailable)) } as HostRead)
        case .passkeysAvailable: address({ CEFMirrorExports.int(CEFMirrorKey(.passkeysAvailable)) } as HostRead)
        case .passwordCoreAvailable: address({ CEFMirrorExports.int(CEFMirrorKey(.passwordCoreAvailable)) } as HostRead)
        case .extLoadLaterSupported: address({ CEFMirrorExports.int(CEFMirrorKey(.extLoadLaterSupported)) } as HostRead)
        case .windowID: address({ CEFMirrorExports.int(CEFMirrorKey(.windowID, id: $0)) } as TabRead)
        case .devToolsBrowser: address({ CEFMirrorExports.int(CEFMirrorKey(.devToolsBrowser, id: $0)) } as TabRead)
        case .navigationEntries: unsafe address({ unsafe CEFMirrorExports.string(CEFMirrorKey(.navigationEntries, id: $0)) } as TabString)
        case .navigationState: unsafe address({ unsafe CEFMirrorExports.string(CEFMirrorKey(.navigationState, id: $0)) } as TabString)
        case .extActions:
            unsafe address({ unsafe CEFMirrorExports.string(CEFMirrorKey(.extActions, id: $0, iconPixels: $1)) } as ActionsString)
        case .extList: unsafe address({ unsafe CEFMirrorExports.string(CEFMirrorKey(.extList, id: $0)) } as TabString)
        case .extCommands: unsafe address({ unsafe CEFMirrorExports.string(CEFMirrorKey(.extCommands, id: $0)) } as TabString)
        case .sidePanelState: unsafe address({ unsafe CEFMirrorExports.string(CEFMirrorKey(.sidePanelState, id: $0)) } as TabString)
        case .omniboxKeywords: unsafe address({ unsafe CEFMirrorExports.string(CEFMirrorKey(.omniboxKeywords, id: $0)) } as TabString)
        case .popupWindowBounds:
            unsafe address({ unsafe CEFMirrorExports.bounds(CEFMirrorKey(.popupWindowBounds, id: $0), $1, $2, $3, $4) } as BoundsRead)
        case .devToolsInspectedBounds:
            unsafe address({ unsafe CEFMirrorExports.bounds(CEFMirrorKey(.devToolsInspectedBounds, id: $0), $1, $2, $3, $4) } as BoundsRead)
        case .rendererClientIDs:
            unsafe address({ unsafe CEFMirrorExports.ids(CEFMirrorKey(.rendererClientIDs, id: $0), $1, $2) } as IDsRead)
        }
    }

    /// A C function's address, which `CEFShimLibrary.Resolver` casts back to the same C type.
    private static func address<Function>(_ function: Function) -> UInt {
        // SAFETY: every caller passes a `@convention(c)` function of the export's C type (the `as` casts in
        // `functionAddress(named:)`), which is pointer-sized; only its address is taken.
        unsafe unsafeBitCast(function, to: UInt.self)
    }

    private static func int(_ key: CEFMirrorKey) -> Int32 {
        guard Thread.isMainThread else { return offMain(key.field.export, 0) }
        return MainActor.assumeIsolated { // main-proof: guarded by Thread.isMainThread above
            if case .int(let value)? = served?.value(key) { value } else { 0 }
        }
    }

    private static func string(_ key: CEFMirrorKey) -> UnsafeMutablePointer<CChar>? {
        guard Thread.isMainThread else { return offMain(key.field.export, nil) }
        let address = MainActor.assumeIsolated { () -> UInt in // main-proof: guarded by Thread.isMainThread above
            // SAFETY: only the copy's address crosses out of the main-actor closure; the C caller owns the copy.
            unsafe served?.handOutString(key).map { unsafe UInt(bitPattern: $0) } ?? 0
        }
        // SAFETY: the address of the copy handOutString made (or 0, NULL), handed to the C caller as is.
        return unsafe UnsafeMutablePointer(bitPattern: address)
    }

    private static func bounds(
        _ key: CEFMirrorKey, _ x: UnsafeMutablePointer<Int32>?, _ y: UnsafeMutablePointer<Int32>?,
        _ width: UnsafeMutablePointer<Int32>?, _ height: UnsafeMutablePointer<Int32>?
    ) -> Int32 {
        guard Thread.isMainThread else { return offMain(key.field.export, 0) }
        let bounds = MainActor.assumeIsolated { () -> CEFMirrorValue.Bounds in // main-proof: guarded by Thread.isMainThread above
            if case .bounds(let bounds)? = served?.value(key) { bounds } else { CEFMirrorValue.Bounds() }
        }
        // SAFETY: each non-NULL out-parameter is the caller's Int32, writable during this call (the C ABI).
        unsafe x?.pointee = bounds.x
        // SAFETY: as for x.
        unsafe y?.pointee = bounds.y
        // SAFETY: as for x.
        unsafe width?.pointee = bounds.width
        // SAFETY: as for x.
        unsafe height?.pointee = bounds.height
        return bounds.result
    }

    /// The ids that fit `capacity` into `out`; returns how many the value holds, as the shim does.
    private static func ids(_ key: CEFMirrorKey, _ out: UnsafeMutablePointer<Int32>?, _ capacity: Int32) -> Int32 {
        guard Thread.isMainThread else { return offMain(key.field.export, 0) }
        let ids = MainActor.assumeIsolated { () -> [Int32] in // main-proof: guarded by Thread.isMainThread above
            if case .ints(let ids)? = served?.value(key) { ids } else { [] }
        }
        for (index, id) in ids.prefix(Int(max(capacity, 0))).enumerated() {
            // SAFETY: a non-NULL `out` is the caller's buffer of `capacity` Int32s, writable during this call (the
            // C ABI); `index` stays below `capacity`.
            unsafe out?[index] = id
        }
        return Int32(ids.count)
    }

    /// Off the main thread nothing can tell whose string it is, so it stays allocated.
    private static func free(_ pointer: UnsafeMutablePointer<CChar>?) {
        // SAFETY: only the address is read here; the main-actor closure turns it back for the cache's free.
        let address = unsafe UInt(bitPattern: pointer)
        guard address != 0 else { return }
        guard Thread.isMainThread else { return offMain("cmux_shim_free", ()) }
        MainActor.assumeIsolated { // main-proof: guarded by Thread.isMainThread above
            // SAFETY: the string the C caller frees, once (CEFMirrorCache.free).
            if let pointer = unsafe UnsafeMutablePointer<CChar>(bitPattern: address) { unsafe served?.free(pointer) }
        }
    }

    private static func offMain<Value>(_ export: String, _ zero: Value) -> Value {
        logger.fault("deferred CEF events: \(export, privacy: .public) called off the main thread")
        return zero
    }
}
