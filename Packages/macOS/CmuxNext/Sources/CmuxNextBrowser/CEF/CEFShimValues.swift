import AppKit

/// An out-parameter read of the shim (`cmux_shim_popup_window_bounds`,
/// `cmux_shim_devtools_inspected_bounds`): the call's result and the four ints it wrote (0 where it
/// wrote none). ``CEFShimLibrary`` owns the out-parameters, so no caller holds a pointer.
nonisolated struct CEFShimBounds: Equatable, Sendable {
    var result: Int32 = 0
    var x: Int32 = 0
    var y: Int32 = 0
    var width: Int32 = 0
    var height: Int32 = 0
}

/// The `parent_view` argument of the shim's window calls (`create_window`,
/// `create_placeholder_window`, `popup_window_attach`, `devtools_set_placement`): an NSView in
/// process, a page view token in host mode, which the remote shim sends as is
/// (``CEFPaneHost/pageParent()``). Only its bits are kept; ``CEFShimLibrary`` turns them into the C
/// argument for the call.
nonisolated struct CEFParentView: Equatable, Sendable {
    private let bits: UInt

    /// In process: `view`, unretained. Whoever passes it keeps the view alive while Chromium's window
    /// uses it, as the pane host keeps its host view and DevTools its own.
    @MainActor init(view: NSView) {
        // Only the view's address (its identity's bits); it reaches the shim as the parent view, which the
        // caller keeps alive (above). No retain count changes.
        bits = UInt(bitPattern: ObjectIdentifier(view))
    }

    /// Host mode: the token cmux minted for a page view (``ChromiumHostPageView/wireToken``).
    init(token: UInt64) {
        bits = UInt(token)
    }

    /// The C argument: the view's address, or the token as a pointer-sized value.
    var pointer: UnsafeMutableRawPointer? {
        unsafe UnsafeMutableRawPointer(bitPattern: bits)
    }
}

/// A key callback's `NSEvent*` (the shim's `key_fn`), kept as its address until the main-actor
/// closure reads it back: a raw pointer does not cross into that closure.
nonisolated struct CEFKeyEventAddress: Sendable {
    private let bits: UInt

    init(_ event: UnsafeMutableRawPointer?) {
        // SAFETY: only the address is read here; `event()` turns it back during the same callback.
        bits = unsafe UInt(bitPattern: event)
    }

    /// The shim passed an event.
    var isSome: Bool { bits != 0 }

    /// The event, unretained. Call it only during the key callback that made this: the shim's `NSEvent`
    /// lives until that callback returns.
    @MainActor func event() -> NSEvent? {
        // SAFETY: a nonzero address is the live NSEvent of the running callback (above); the read does not
        // change its count.
        unsafe UnsafeMutableRawPointer(bitPattern: bits).map { unsafe Unmanaged<NSEvent>.fromOpaque($0).takeUnretainedValue() }
    }
}
