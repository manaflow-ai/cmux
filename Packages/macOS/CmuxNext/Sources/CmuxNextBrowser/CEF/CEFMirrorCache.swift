import Darwin
import Foundation

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

    /// Why ``shim(helloNow:)`` could not serve this cache.
    enum ServeError: Error, CustomStringConvertible {
        /// Another cache is served and a shim over it is alive: the C exports have one cache.
        case anotherCacheServed
        case shim(CEFShimLibrary.LoadError)

        var description: String {
            switch self {
            case .anotherCacheServed: "another runtime's mirror cache is served"
            case .shim(let error): "shim: \(error)"
            }
        }
    }

    /// A shim whose mirror exports read this cache (``CEFMirrorExports``) and whose other exports
    /// are `source`'s. The fork's capabilities are read now, as the remote shim takes them from the
    /// host's hello (`attach`). With `helloNow` (Chromium is up already) the counts are too; without
    /// it they wait for CONTEXT_INITIALIZED's batch, as no browser or window list exists before
    /// `CefInitialize`.
    func shim(helloNow: Bool) throws(ServeError) -> CEFShimLibrary {
        if let served = CEFMirrorExports.served, served !== self { throw .anotherCacheServed }
        let overriding: CEFShimLibrary
        do throws(CEFShimLibrary.LoadError) {
            // The shim holds this cache: `served` stays it while any copy of the shim is alive.
            overriding = try source.overriding { [self] name in
                withExtendedLifetime(self) { CEFMirrorExports.function(named: name) }
            }
        } catch {
            throw .shim(error)
        }
        let hello = CEFMirrorField.allCases.filter { helloNow ? $0.isHostWide : $0.isCapability }
        apply(hello.map { refreshed(CEFMirrorKey($0)) })
        CEFMirrorExports.served = self
        return overriding
    }

    /// The values `event` refreshes, read from `source` now: the host pushes them before the event,
    /// in the same batch. Each key is scoped as its export reads it (``CEFMirrorField/keyID(browser:window:)``).
    func updates(for event: CEFShimEvent) -> [Update] {
        guard let hit = event.mirrorTrigger else { return [] }
        return CEFMirrorField.refreshed(by: hit.trigger).map { field in
            refreshed(CEFMirrorKey(field, id: field.keyID(browser: hit.browser, window: hit.window),
                                   iconPixels: field == .extActions ? CEFExtensionAction.iconPixels : 0))
        }
    }

    func apply(_ updates: [Update]) {
        for update in updates { values[update.key] = update.value }
    }

    /// The value a mirror read of `key` answers with; nil when no batch pushed one.
    func value(_ key: CEFMirrorKey) -> CEFMirrorValue? { values[key] }

    /// A copy of `key`'s string for a C caller, which frees it with `cmux_shim_free`; NULL when no
    /// batch pushed one.
    func handOutString(_ key: CEFMirrorKey) -> UnsafeMutablePointer<CChar>? {
        guard case .string(let text)? = values[key], let copy = strdup(text) else { return nil }
        handedOut.insert(UInt(bitPattern: copy))
        return copy
    }

    /// `cmux_shim_free`: a copy ``handOutString(_:)`` made is freed here; any other string is the
    /// source shim's (the one served cache's shim made it, so it came from this `source`).
    func free(_ pointer: UnsafeMutablePointer<CChar>) {
        if handedOut.remove(UInt(bitPattern: pointer)) != nil {
            Darwin.free(pointer)
        } else {
            source.free(pointer)
        }
    }

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

    private static func bounds(_ read: CEFMirrorExports.BoundsRead, _ id: Int32) -> CEFMirrorValue.Bounds {
        var x: Int32 = 0, y: Int32 = 0, width: Int32 = 0, height: Int32 = 0
        let result = read(id, &x, &y, &width, &height)
        return CEFMirrorValue.Bounds(result: result, x: x, y: y, width: width, height: height)
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
