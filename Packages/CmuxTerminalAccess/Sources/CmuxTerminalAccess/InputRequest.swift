// SPDX-License-Identifier: MIT

/// A single write request. `focusSurface` is the explicit opt-in to
/// in-app focus movement before the payload is dispatched (D17 —
/// ``DefaultTerminalAccessService/writeInput(_:)`` calls
/// ``SurfaceProvider/setFocus(surface:gained:)`` first when true).
public struct InputRequest: Sendable, Hashable {
    /// The surface to deliver the payload to.
    public let handle: SurfaceHandle
    /// The payload to dispatch.
    public let payload: InputPayload
    /// When `true`, the service moves in-app focus to the target surface
    /// before dispatching the payload (D17). Defaults to `false`.
    public let focusSurface: Bool

    /// Creates an input request. `focusSurface` defaults to `false` per
    /// D17 — focus changes must be explicitly opted into.
    public init(handle: SurfaceHandle, payload: InputPayload, focusSurface: Bool = false) {
        self.handle = handle
        self.payload = payload
        self.focusSurface = focusSurface
    }
}
