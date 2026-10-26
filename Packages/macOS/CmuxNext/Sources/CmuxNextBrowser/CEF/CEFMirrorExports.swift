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
    typealias Free = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    /// The cache the functions read. A C function of the shim's ABI carries no context, so the
    /// process has one, as the remote shim's cache is its dylib's (the last `CEFMirrorCache.shim()`).
    @MainActor static weak var served: CEFMirrorCache?

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef")

    /// The function for a mirror export or `cmux_shim_free`; nil for every other export.
    static func function(named name: String) -> UnsafeMutableRawPointer? {
        if name == "cmux_shim_free" { return address({ CEFMirrorExports.free($0) } as Free) }
        guard let field = CEFMirrorField.allCases.first(where: { $0.export == name }) else { return nil }
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
        case .windowID: address({ CEFMirrorExports.int(CEFMirrorKey(.windowID, id: $0)) } as TabRead)
        case .devToolsBrowser: address({ CEFMirrorExports.int(CEFMirrorKey(.devToolsBrowser, id: $0)) } as TabRead)
        case .navigationEntries: address({ CEFMirrorExports.string(CEFMirrorKey(.navigationEntries, id: $0)) } as TabString)
        case .navigationState: address({ CEFMirrorExports.string(CEFMirrorKey(.navigationState, id: $0)) } as TabString)
        case .extActions: address({ CEFMirrorExports.string(CEFMirrorKey(.extActions, id: $0, iconPixels: $1)) } as ActionsString)
        case .extList: address({ CEFMirrorExports.string(CEFMirrorKey(.extList, id: $0)) } as TabString)
        case .extCommands: address({ CEFMirrorExports.string(CEFMirrorKey(.extCommands, id: $0)) } as TabString)
        case .sidePanelState: address({ CEFMirrorExports.string(CEFMirrorKey(.sidePanelState, id: $0)) } as TabString)
        case .omniboxKeywords: address({ CEFMirrorExports.string(CEFMirrorKey(.omniboxKeywords, id: $0)) } as TabString)
        case .popupWindowBounds:
            address({ CEFMirrorExports.bounds(CEFMirrorKey(.popupWindowBounds, id: $0), $1, $2, $3, $4) } as BoundsRead)
        case .devToolsInspectedBounds:
            address({ CEFMirrorExports.bounds(CEFMirrorKey(.devToolsInspectedBounds, id: $0), $1, $2, $3, $4) } as BoundsRead)
        }
    }

    private static func address<Function>(_ function: Function) -> UnsafeMutableRawPointer {
        unsafeBitCast(function, to: UnsafeMutableRawPointer.self)
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
            served?.handOutString(key).map { UInt(bitPattern: $0) } ?? 0
        }
        return UnsafeMutablePointer(bitPattern: address)
    }

    private static func bounds(
        _ key: CEFMirrorKey, _ x: UnsafeMutablePointer<Int32>?, _ y: UnsafeMutablePointer<Int32>?,
        _ width: UnsafeMutablePointer<Int32>?, _ height: UnsafeMutablePointer<Int32>?
    ) -> Int32 {
        guard Thread.isMainThread else { return offMain(key.field.export, 0) }
        let bounds = MainActor.assumeIsolated { () -> CEFMirrorValue.Bounds in // main-proof: guarded by Thread.isMainThread above
            if case .bounds(let bounds)? = served?.value(key) { bounds } else { CEFMirrorValue.Bounds() }
        }
        x?.pointee = bounds.x
        y?.pointee = bounds.y
        width?.pointee = bounds.width
        height?.pointee = bounds.height
        return bounds.result
    }

    /// Off the main thread nothing can tell whose string it is, so it stays allocated.
    private static func free(_ pointer: UnsafeMutablePointer<CChar>?) {
        guard let pointer else { return }
        guard Thread.isMainThread else { return offMain("cmux_shim_free", ()) }
        let address = UInt(bitPattern: pointer)
        MainActor.assumeIsolated { // main-proof: guarded by Thread.isMainThread above
            if let pointer = UnsafeMutablePointer<CChar>(bitPattern: address) { served?.free(pointer) }
        }
    }

    private static func offMain<Value>(_ export: String, _ zero: Value) -> Value {
        logger.fault("deferred CEF events: \(export, privacy: .public) called off the main thread")
        return zero
    }
}
