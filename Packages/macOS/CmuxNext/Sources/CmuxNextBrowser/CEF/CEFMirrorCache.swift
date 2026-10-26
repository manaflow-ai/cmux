import Darwin
import Foundation
import os

nonisolated private let mirrorLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef")

/// The deferred-event mode's mirror reads (``CEFDeferredEvents``, task 231 of
/// plans/cmux-next/chrome-parity/p01-process.md): the shim's `mirror` exports
/// (plans/cmux-next/chromium-host-ops.json) answer from the values the last event batch pushed, as
/// the remote shim's cache does (ChromiumHost/client/remote_shim_mirror.h), never from Chromium in
/// the caller's turn. Chrome answers NSTextInputClient queries the same way, from the TextInputState
/// the renderer pushed (content/browser/renderer_host/text_input_manager.cc).
///
/// A key no batch pushed reads as the C zero value (0 or NULL), as in the remote shim. Posts do not
/// mark keys pending here (task 016b's read-your-writes is the remote shim's).
final class CEFMirrorCache {
    /// The shim the values are read from when an event refreshes them (the in-process shim).
    let source: CEFShimLibrary
    private var values: [CEFMirrorKey: CEFMirrorValue] = [:]
    /// Strings a mirror read handed out (`strdup`), until the caller frees them with `cmux_shim_free`.
    private var handedOut: Set<UInt> = []

    /// A key's value as one batch pushes it; nil forgets the key (the source answered 0 or NULL).
    nonisolated struct Update: Equatable, Sendable {
        let key: CEFMirrorKey
        let value: CEFMirrorValue?
    }

    init(source: CEFShimLibrary) {
        self.source = source
    }

    /// A shim whose mirror exports read this cache and whose other exports are `source`'s. The fork's
    /// capabilities are read now, as the remote shim takes them from the host's hello (`attach`); the
    /// counts wait for their events (no browser exists before `CefInitialize`, and the fork's window
    /// list may not be there to ask).
    func shim() throws(CEFShimLibrary.LoadError) -> CEFShimLibrary {
        apply(CEFMirrorField.allCases.filter(\.isCapability).map { refreshed(CEFMirrorKey($0)) })
        Self.served = self
        return try source.overriding(Self.function(named:))
    }

    /// The values `event` refreshes, read from `source` now: the host pushes them before the event,
    /// in the same batch.
    func updates(for event: CEFShimEvent) -> [Update] {
        guard let hit = event.mirrorTrigger else { return [] }
        return CEFMirrorField.refreshed(by: hit.trigger).map { field in
            refreshed(CEFMirrorKey(field, id: field == .popupWindowBounds ? hit.window : hit.browser,
                                   iconPixels: field == .extActions ? CEFExtensionAction.iconPixels : 0))
        }
    }

    func apply(_ updates: [Update]) {
        for update in updates { values[update.key] = update.value }
    }

    /// The value a mirror read of `key` answers with; nil when no batch pushed one.
    func value(_ key: CEFMirrorKey) -> CEFMirrorValue? { values[key] }

    private func refreshed(_ key: CEFMirrorKey) -> Update {
        Update(key: key, value: read(key))
    }

    private func read(_ key: CEFMirrorKey) -> CEFMirrorValue? {
        let shim = source
        let id = key.id
        switch key.field {
        case .forkAPIVersion: return .int(shim.forkAPIVersion())
        case .placeholderSupported: return .int(shim.placeholderSupported())
        case .navigationRestoreSupported: return .int(shim.navigationRestoreSupported())
        case .foreignBrowserCount: return .int(shim.foreignBrowserCount())
        case .liveBrowserCount: return .int(shim.liveBrowserCount())
        case .windowCount: return .int(shim.windowCount())
        case .passwordImportAvailable: return .int(shim.passwordImportAvailable())
        case .passwordReplaceAvailable: return .int(shim.passwordReplaceAvailable())
        case .passkeysAvailable: return .int(shim.passkeysAvailable())
        case .passwordCoreAvailable: return .int(shim.passwordCoreAvailable())
        case .windowID: return .int(shim.tabWindowID(id))
        case .devToolsBrowser: return .int(shim.devToolsBrowser(id))
        case .navigationEntries: return shim.takeString(shim.tabNavigationEntries(id)).map(CEFMirrorValue.string)
        case .navigationState: return shim.takeString(shim.tabNavigationState(id)).map(CEFMirrorValue.string)
        case .extActions: return shim.takeString(shim.extActions(id, key.iconPixels)).map(CEFMirrorValue.string)
        case .extList: return shim.takeString(shim.extList(id)).map(CEFMirrorValue.string)
        case .extCommands: return shim.takeString(shim.extCommands(id)).map(CEFMirrorValue.string)
        case .sidePanelState: return shim.takeString(shim.sidePanelState(id)).map(CEFMirrorValue.string)
        case .omniboxKeywords: return shim.takeString(shim.omniboxKeywords(id)).map(CEFMirrorValue.string)
        case .popupWindowBounds: return .bounds(Self.bounds(shim.popupWindowBounds, id))
        case .devToolsInspectedBounds: return .bounds(Self.bounds(shim.devToolsInspectedBounds, id))
        }
    }

    private static func bounds(_ read: BoundsRead, _ id: Int32) -> CEFMirrorValue.Bounds {
        var x: Int32 = 0, y: Int32 = 0, width: Int32 = 0, height: Int32 = 0
        let result = read(id, &x, &y, &width, &height)
        return CEFMirrorValue.Bounds(result: result, x: x, y: y, width: width, height: height)
    }

    // MARK: The mirror exports

    /// The cache the mirror exports read: a C function pointer carries no context, so the process
    /// has one, as the remote shim's cache is its dylib's (the last ``shim()`` made).
    private static weak var served: CEFMirrorCache?

    private typealias HostRead = @convention(c) () -> Int32
    private typealias TabRead = @convention(c) (Int32) -> Int32
    private typealias TabString = @convention(c) (Int32) -> UnsafeMutablePointer<CChar>?
    private typealias ActionsString = @convention(c) (Int32, Int32) -> UnsafeMutablePointer<CChar>?
    private typealias BoundsRead = @convention(c) (Int32, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?,
                                                   UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Int32
    private typealias Free = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    /// This cache's function for a mirror export or `cmux_shim_free` (which frees the copies the
    /// string reads hand out); nil for every other export.
    private nonisolated static func function(named name: String) -> UnsafeMutableRawPointer? {
        if name == "cmux_shim_free" { return address({ CEFMirrorCache.servedFree($0) } as Free) }
        guard let field = CEFMirrorField.allCases.first(where: { $0.export == name }) else { return nil }
        return switch field {
        case .forkAPIVersion: address({ CEFMirrorCache.servedInt(CEFMirrorKey(.forkAPIVersion)) } as HostRead)
        case .placeholderSupported: address({ CEFMirrorCache.servedInt(CEFMirrorKey(.placeholderSupported)) } as HostRead)
        case .navigationRestoreSupported: address({ CEFMirrorCache.servedInt(CEFMirrorKey(.navigationRestoreSupported)) } as HostRead)
        case .foreignBrowserCount: address({ CEFMirrorCache.servedInt(CEFMirrorKey(.foreignBrowserCount)) } as HostRead)
        case .liveBrowserCount: address({ CEFMirrorCache.servedInt(CEFMirrorKey(.liveBrowserCount)) } as HostRead)
        case .windowCount: address({ CEFMirrorCache.servedInt(CEFMirrorKey(.windowCount)) } as HostRead)
        case .passwordImportAvailable: address({ CEFMirrorCache.servedInt(CEFMirrorKey(.passwordImportAvailable)) } as HostRead)
        case .passwordReplaceAvailable: address({ CEFMirrorCache.servedInt(CEFMirrorKey(.passwordReplaceAvailable)) } as HostRead)
        case .passkeysAvailable: address({ CEFMirrorCache.servedInt(CEFMirrorKey(.passkeysAvailable)) } as HostRead)
        case .passwordCoreAvailable: address({ CEFMirrorCache.servedInt(CEFMirrorKey(.passwordCoreAvailable)) } as HostRead)
        case .windowID: address({ CEFMirrorCache.servedInt(CEFMirrorKey(.windowID, id: $0)) } as TabRead)
        case .devToolsBrowser: address({ CEFMirrorCache.servedInt(CEFMirrorKey(.devToolsBrowser, id: $0)) } as TabRead)
        case .navigationEntries: address({ CEFMirrorCache.servedString(CEFMirrorKey(.navigationEntries, id: $0)) } as TabString)
        case .navigationState: address({ CEFMirrorCache.servedString(CEFMirrorKey(.navigationState, id: $0)) } as TabString)
        case .extActions: address({ CEFMirrorCache.servedString(CEFMirrorKey(.extActions, id: $0, iconPixels: $1)) } as ActionsString)
        case .extList: address({ CEFMirrorCache.servedString(CEFMirrorKey(.extList, id: $0)) } as TabString)
        case .extCommands: address({ CEFMirrorCache.servedString(CEFMirrorKey(.extCommands, id: $0)) } as TabString)
        case .sidePanelState: address({ CEFMirrorCache.servedString(CEFMirrorKey(.sidePanelState, id: $0)) } as TabString)
        case .omniboxKeywords: address({ CEFMirrorCache.servedString(CEFMirrorKey(.omniboxKeywords, id: $0)) } as TabString)
        case .popupWindowBounds:
            address({ CEFMirrorCache.servedBounds(CEFMirrorKey(.popupWindowBounds, id: $0), $1, $2, $3, $4) } as BoundsRead)
        case .devToolsInspectedBounds:
            address({ CEFMirrorCache.servedBounds(CEFMirrorKey(.devToolsInspectedBounds, id: $0), $1, $2, $3, $4) } as BoundsRead)
        }
    }

    private nonisolated static func address<Function>(_ function: Function) -> UnsafeMutableRawPointer {
        unsafeBitCast(function, to: UnsafeMutableRawPointer.self)
    }

    // Every shim call is the main thread's, as the remote shim asserts: a read elsewhere gets the C
    // zero value and a fault, never Chromium's live answer.

    private nonisolated static func servedInt(_ key: CEFMirrorKey) -> Int32 {
        guard Thread.isMainThread else { return offMain(key, 0) }
        return MainActor.assumeIsolated { // main-proof: guarded by Thread.isMainThread above
            if case .int(let value)? = Self.served?.values[key] { value } else { 0 }
        }
    }

    private nonisolated static func servedString(_ key: CEFMirrorKey) -> UnsafeMutablePointer<CChar>? {
        guard Thread.isMainThread else { return offMain(key, nil) }
        let address = MainActor.assumeIsolated { () -> UInt in // main-proof: guarded by Thread.isMainThread above
            guard let served = Self.served, case .string(let text)? = served.values[key], let copy = strdup(text) else { return 0 }
            let address = UInt(bitPattern: copy)
            served.handedOut.insert(address)
            return address
        }
        return UnsafeMutablePointer(bitPattern: address)
    }

    private nonisolated static func servedBounds(
        _ key: CEFMirrorKey, _ x: UnsafeMutablePointer<Int32>?, _ y: UnsafeMutablePointer<Int32>?,
        _ width: UnsafeMutablePointer<Int32>?, _ height: UnsafeMutablePointer<Int32>?
    ) -> Int32 {
        guard Thread.isMainThread else { return offMain(key, 0) }
        let bounds = MainActor.assumeIsolated { () -> CEFMirrorValue.Bounds in // main-proof: guarded by Thread.isMainThread above
            if case .bounds(let bounds)? = Self.served?.values[key] { bounds } else { CEFMirrorValue.Bounds() }
        }
        x?.pointee = bounds.x
        y?.pointee = bounds.y
        width?.pointee = bounds.width
        height?.pointee = bounds.height
        return bounds.result
    }

    /// `cmux_shim_free`: a copy a mirror read handed out is this cache's; any other string is the
    /// source shim's. Off the main thread nothing can tell which, so the string stays allocated.
    private nonisolated static func servedFree(_ pointer: UnsafeMutablePointer<CChar>?) {
        guard let pointer else { return }
        guard Thread.isMainThread else {
            mirrorLogger.fault("deferred CEF events: cmux_shim_free off the main thread; the string is not freed")
            return
        }
        let address = UInt(bitPattern: pointer)
        MainActor.assumeIsolated { // main-proof: guarded by Thread.isMainThread above
            guard let served = Self.served else { return }
            if served.handedOut.remove(address) != nil {
                Darwin.free(UnsafeMutableRawPointer(bitPattern: address))
            } else {
                served.source.free(UnsafeMutablePointer(bitPattern: address))
            }
        }
    }

    private nonisolated static func offMain<Value>(_ key: CEFMirrorKey, _ zero: Value) -> Value {
        mirrorLogger.fault("deferred CEF events: \(key.field.export, privacy: .public) read off the main thread")
        return zero
    }
}

/// One mirror read's arguments: the export's `mirror_key` with its key arguments.
nonisolated struct CEFMirrorKey: Hashable, Sendable {
    let field: CEFMirrorField
    /// The browser id, or the window id for `popup_window.bounds`; 0 for a host-wide key.
    let id: Int32
    /// `icon_px` of `tab.ext_actions` (`CEFExtensionAction.iconPixels` at every site); 0 for others.
    let iconPixels: Int32

    init(_ field: CEFMirrorField, id: Int32 = 0, iconPixels: Int32 = 0) {
        self.field = field
        self.id = id
        self.iconPixels = iconPixels
    }
}

nonisolated enum CEFMirrorValue: Equatable, Sendable {
    case int(Int32)
    case string(String)
    case bounds(Bounds)

    /// An out-parameter read's return value and outputs.
    nonisolated struct Bounds: Equatable, Sendable {
        var result: Int32 = 0
        var x: Int32 = 0
        var y: Int32 = 0
        var width: Int32 = 0
        var height: Int32 = 0
    }
}
