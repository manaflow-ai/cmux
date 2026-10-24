import Foundation

/// Whether a pane on screen presents one pane tab now, for every ``HomeNativeTranscriptView`` inside
/// the tab's content.
///
/// A transcript cannot tell from its geometry whether a person sees it: a pane scrolled out of the
/// strip or covered by a docked column keeps its frame, its window and every hidden flag. The layout
/// knows (its pane presence reaches the app's content cache), so the one view that stands for the tab
/// (``PanePresenceHost``: a page tab's view, a conversation tab's view, a window's top page) owns one
/// `PanePresence`, and the tab's owner sets ``isPresented`` from the cache. Each transcript takes the
/// presence of its nearest host ancestor when it moves into a window and hears its changes, so no
/// container between the host and the transcript forwards anything. A transcript with no host
/// ancestor is not presented (fail closed).
///
/// ```swift
/// let presence = PanePresence(isPresented: cache.isRendering(tab.id))
/// let view = HomeHostView(services: services, conversation: id, presence: presence)
/// // On each presentation change:
/// presence.isPresented = cache.isRendering(tab.id)
/// ```
@MainActor
public final class PanePresence {
    /// Whether a pane on screen presents the tab: each transcript that follows this presence
    /// re-reads it (its window notices and reads) when it changes.
    public var isPresented: Bool {
        didSet {
            guard isPresented != oldValue else { return }
            for follower in followers.allObjects { follower.followWindow() }
        }
    }

    /// The transcripts inside the host now (weak: a transcript leaves when it leaves its window).
    private let followers = NSHashTable<HomeNativeTranscriptView>.weakObjects()

    /// - Parameter isPresented: the tab's presence when its content is made, before any pane
    ///   presents it (the content cache's rendering set for a pane tab, `true` for a window's top
    ///   page, which no pane holds).
    public init(isPresented: Bool) {
        self.isPresented = isPresented
    }

    func add(_ transcript: HomeNativeTranscriptView) { followers.add(transcript) }
    func remove(_ transcript: HomeNativeTranscriptView) { followers.remove(transcript) }
}
