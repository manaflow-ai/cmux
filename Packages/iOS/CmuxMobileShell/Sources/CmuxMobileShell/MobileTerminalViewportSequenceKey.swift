/// The owner of a viewport generation fence.
///
/// Surface identifiers are only Mac-local. Sibling app builds can reuse the
/// same identifier, while a warm multi-Mac focus handoff keeps each Mac's
/// connection and its generation tombstones alive. The producer sequence must
/// therefore be scoped to the exact Mac app instance as well as the surface.
struct MobileTerminalViewportSequenceKey: Hashable, Sendable {
    let ownerKey: MacPairingKey
    let surfaceID: String
}
