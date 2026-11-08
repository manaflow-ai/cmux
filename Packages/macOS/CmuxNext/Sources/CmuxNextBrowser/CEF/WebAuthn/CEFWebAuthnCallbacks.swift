import Foundation

/// The seam between the shim's WebAuthn delegate (`cmux_shim_webauthn_request_fn` / `_cancel_fn`)
/// and ``CEFWebAuthnPrompts``. The shim calls on the CEF UI thread, which is the main thread; the
/// context is the prompts object `install()` retained. The JSON is copied before any hop.
nonisolated enum CEFWebAuthnCallbacks {
    static let request: CEFShimLibrary.WebAuthnRequestFn = { context, json in
        let address = UInt(bitPattern: context)
        let text = json.map { String(cString: $0) } ?? ""
        guard Thread.isMainThread else {
            // task-owner: one hop when a fork calls off the UI thread; the request stays open in Chromium meanwhile.
            Task { @MainActor in prompts(at: address)?.arrived(json: text) }
            return
        }
        // main-proof: guarded by Thread.isMainThread above
        MainActor.assumeIsolated { prompts(at: address)?.arrived(json: text) }
    }

    static let cancel: CEFShimLibrary.WebAuthnCancelFn = { context, id, _ in
        let address = UInt(bitPattern: context)
        guard Thread.isMainThread else {
            // task-owner: one hop, as in `request`.
            Task { @MainActor in prompts(at: address)?.cancelled(id) }
            return
        }
        // main-proof: guarded by Thread.isMainThread above
        MainActor.assumeIsolated { prompts(at: address)?.cancelled(id) }
    }

    /// The prompts object behind a delegate context (retained for the process by `install()`).
    @MainActor
    private static func prompts(at address: UInt) -> CEFWebAuthnPrompts? {
        UnsafeRawPointer(bitPattern: address).map { Unmanaged<CEFWebAuthnPrompts>.fromOpaque($0).takeUnretainedValue() }
    }
}
