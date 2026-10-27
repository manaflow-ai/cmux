/// One saved frame of the app-wide hidden-frame list: an evicted terminal's last frame.
public struct HiddenFrameID: Hashable, Sendable {
    /// What kind of frame it is.
    ///
    /// Only frames whose eviction frees their bytes are kinds. A browser pane's hosted page is not
    /// one yet: its view holds only a `CALayerHost` of the page window's remote context, so dropping
    /// it frees nothing while Chromium keeps the page's compositor surface. It joins when the fork can
    /// drop that surface (Chrome's `DelegatedFrameHost::EvictDelegatedFrame`).
    public enum Kind: String, Hashable, Sendable {
        /// An evicted terminal's last presented frame (`TerminalLastFrames`): a real IOSurface.
        case terminal
    }

    public let kind: Kind
    /// The owner's key: a terminal's tab key.
    public let key: String

    public init(kind: Kind, key: String) {
        self.kind = kind
        self.key = key
    }
}

/// Where panes put the frames they keep while hidden: the App's one `HiddenFrameLRU`
/// (CmuxNextHibernation), a fake in tests.
///
/// Chrome's `components/viz/client/frame_eviction_manager.h` client side: a holder adds its frame
/// with a callback that drops it (`FrameEvictionManagerClient::EvictCurrentFrame`), locks it while
/// it is shown or read, and removes it when the frame goes on its own. The keeper decides which
/// unlocked frame goes and when; it may call `evict` on a later turn than the one that decided it.
@MainActor
public protocol HiddenFrameKeeper: AnyObject {
    /// `id` holds a frame now (it replaces an earlier one of `id`): locked when `locked`, else the
    /// most recently used unlocked frame. `evict` drops the frame when the keeper culls it; the
    /// keeper has forgotten `id` before it calls `evict`.
    func add(_ id: HiddenFrameID, locked: Bool, evict: @escaping @MainActor () -> Void)
    /// `id`'s frame went on its own (shown and taken, closed, purged): the keeper forgets it.
    func remove(_ id: HiddenFrameID)
    /// `id`'s frame is shown or read: it is never evicted until each lock is unlocked.
    func lock(_ id: HiddenFrameID)
    /// One lock of `id` ends; with none left it is the most recently used unlocked frame.
    func unlock(_ id: HiddenFrameID)
}
