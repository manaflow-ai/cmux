public import AppKit

/// When a chat is pictured for the sidebar hover card's split miniature (#51768): on a hover while it is on screen, at
/// most once a ``freshness``, and as it leaves the screen (``willLeaveScreen(_:)``, at most once a
/// ``leaveFreshness``). A hidden chat is never pictured (Chromium pictures no hidden page); the app keeps each picture
/// (`keep`, at most ``side`` px) and shows its last one between pictures; a chat with none yet (hidden since
/// launch) shows its last page: a released chat's held frame, or the page the last quit saved (``AgentPaneLaunchImages``).
@MainActor
public final class AgentPanePictures {
    /// Keeps `image` as tab `key`'s picture.
    public typealias Keep = @MainActor (_ key: String, _ image: CGImage) -> Void

    /// A kept picture's longest side, in pixels: a hover card's thumbnail at most.
    public static let side = 640

    /// A chat on screen pictured this recently is not pictured again on a hover.
    public static let freshness: Duration = .seconds(1)
    /// A chat pictured this recently is not pictured again as it leaves the screen: switching back and forth costs
    /// the main thread one Chromium encode per this, not one per switch.
    public static let leaveFreshness: Duration = .seconds(10)

    private let view: @MainActor (String) -> AgentPaneView?
    private let keep: Keep
    /// Keeps a leave picture past this run (on disk), so a card shows the chat after a relaunch too (#56159).
    private let persist: Keep?
    private let images: AgentPaneLaunchImages?
    private var times: [String: ContinuousClock.Instant] = [:]
    private var inFlight: Set<String> = []

    /// `view` gives a tab's chat view when one is made (nil for every other tab); `persist` also gets each leave
    /// picture, and a hover's at most once a ``leaveFreshness`` per chat, to keep it past this run.
    public init(view: @escaping @MainActor (String) -> AgentPaneView?, images: AgentPaneLaunchImages? = nil, keep: @escaping Keep,
                persist: Keep? = nil) {
        (self.view, self.images, self.keep, self.persist) = (view, images, keep, persist)
    }

    /// Tab `key`'s picture for a hover: a new one of its chat when one can be taken now (``freshPicture(_:fit:)``),
    /// else `kept` (the app's last picture of the tab), else its chat's last page, kept from then on.
    public func picture(_ key: String, fit maxPixelSize: CGSize, kept: () async -> CGImage?) async -> CGImage? {
        if let fresh = await freshPicture(key, fit: maxPixelSize) { return fresh }
        if let image = await kept() { return image }
        // A released chat has no view, so the page is looked up by its tab alone (keys are unique tab ids).
        let appearance = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        guard let page = images?.lastPage(key, appearance: appearance) else { return nil }
        let side = Self.side
        guard let scaled = await Task.detached(priority: .userInitiated, operation: { AgentPaneVideoInfo.scaled(page, toFit: side) }).value
        else { return nil }
        // A newer picture kept while this one scaled wins; the old page never replaces it.
        if let newer = await kept() { return newer }
        keep(key, scaled)  // the next hover reads it from `kept`, not decoding the page again
        return scaled
    }

    /// A new picture of tab `key`'s chat, at most `maxPixelSize`, when it is on screen and its last is older than
    /// ``freshness``; nil asks the caller for its last kept one.
    public func freshPicture(_ key: String, fit maxPixelSize: CGSize) async -> CGImage? {
        // The page picture starts in this turn, right after the on-screen check: a later start could picture it hidden.
        guard let chat = startable(key, within: Self.freshness),
              let kept = await finish(await Self.picture(of: chat), of: chat, key: key) else { return nil }
        persistIfDue(key, kept)  // also below macOS 26, where a leave pictures nothing
        let side = Int(max(maxPixelSize.width, maxPixelSize.height))  // the longest side, as the kept and last-page pictures
        return side >= Self.side ? kept : await Task.detached(priority: .userInitiated) { AgentPaneVideoInfo.scaled(kept, toFit: side) }.value
    }

    /// Tab `key` is about to leave the screen (before its pane shows another view): its chat is pictured now, the
    /// last time it can be, so a hover from another workspace shows it as it was. Started in this turn, while the
    /// page still shows; only where an immediate task can (macOS 26), since a later start could picture a hidden page.
    public func willLeaveScreen(_ key: String) {
        guard #available(macOS 26, *), let chat = startable(key, within: Self.leaveFreshness) else { return }
        Task.immediate { @MainActor [weak self] in  // task-owner: one page picture, started before this turn hides the page
            let image = await Self.picture(of: chat)
            guard let self, let kept = await finish(image, of: chat, key: key) else { return }
            persistedAt[key] = nil
            persistIfDue(key, kept)
        }
    }

    /// `content` (a workspace's view) is about to hide, while it is still on screen: each of `chats` it shows is
    /// pictured now (``willLeaveScreen(_:)``). A pane's own leave comes only after its workspace hid, when its chat
    /// can no longer be pictured, so a chat left by a workspace switch kept no picture and the sidebar card's tile
    /// showed only its title (#56159). Returns the keys of the chats in `content`.
    @discardableResult
    public func willHide(_ content: NSView, chats: [(key: String, view: AgentPaneView)]) -> [String] {
        let shown = chats.filter { $0.view.isDescendant(of: content) }.map(\.key)
        shown.forEach(willLeaveScreen)
        return shown
    }

    /// The chat as the pane shows it: its clear page over its ground (``AgentPaneView/cardPicture(maxPixelWidth:)``).
    private static func picture(of chat: AgentPaneView) async -> CGImage? {
        await chat.cardPicture(maxPixelWidth: CGFloat(side))
    }

    /// When each chat's picture was last persisted: a hover's at most once a ``leaveFreshness``, a leave's always.
    private var persistedAt: [String: ContinuousClock.Instant] = [:]

    private func persistIfDue(_ key: String, _ image: CGImage) {
        guard let persist, persistedAt[key].map({ ContinuousClock.now - $0 >= Self.leaveFreshness }) ?? true else { return }
        persistedAt = persistedAt.filter { view($0.key) != nil }  // closed tabs' times go
        persistedAt[key] = .now
        persist(key, image)
    }

    /// `key`'s painted, on-screen chat, not pictured within `freshness` nor being pictured; marks it in flight.
    private func startable(_ key: String, within freshness: Duration) -> AgentPaneView? {
        guard let chat = view(key), chat.model.newTab == nil, chat.model.hasPainted,
              times[key].map({ ContinuousClock.now - $0 >= freshness }) ?? true,
              AgentPaneHibernationCapture(view: chat).isOnScreen, inFlight.insert(key).inserted else { return nil }
        return chat
    }

    /// Keeps `image`, scaled off the main thread to ``side``, while `chat` is still `key`'s view; ends the capture.
    @discardableResult
    private func finish(_ image: CGImage?, of chat: AgentPaneView, key: String) async -> CGImage? {
        defer { inFlight.remove(key) }
        let side = Self.side
        guard let image, let scaled = await Task.detached(priority: .userInitiated, operation: { AgentPaneVideoInfo.scaled(image, toFit: side) }).value,
              view(key) === chat else { return nil }
        keep(key, scaled)
        times = times.filter { view($0.key) != nil }  // closed tabs' times go
        times[key] = .now
        return scaled
    }
}
