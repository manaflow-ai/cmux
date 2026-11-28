public import AppKit
import CmuxNextCompat

/// One Home conversation's Chief Settings popover, made on its first open (``made(_:)``), and what it
/// shows kept until then: where the Chief runs, its Runs On chip, its name, its avatar and where its
/// picture is kept. A switch between Home conversations builds a new Home (`HomeHostView`), and the
/// card made with it (the popover's own panel window, some 30 controls, the pet's rows, an engine read)
/// cost every switch a main-thread turn for a card most conversations never open (the perf budget's
/// main.turn.motion row, anim-perf chat-open/next/prev: 100 to 116 ms against 8.33 ms on cmux20-bench).
///
/// It also follows the picture the Chief wears where its profile sets none (``followPicture(_:onChange:)``),
/// which the pet's rows in the card did while every Home made them.
@MainActor
public final class HomeChiefSettingsCard {
    /// The popover, once made.
    public private(set) var popover: HomeChiefSettingsPopover?
    private var host = HomeChiefHostLine()
    private var name = ""
    private var avatar: (picture: NSImage?, text: String?)?
    private var pictureStore: (avatars: HomeChiefAvatars, chief: String)?
    private var pictureWatch: Task<Void, Never>?
    private var shownPicture: URL??

    public init() {}

    nonisolated deinit { pictureWatch?.cancel() }

    /// The card's view, once made.
    public var view: HomeChiefSettingsView? { popover?.content }
    /// The popover is on screen.
    public var isShown: Bool { popover?.isShown == true }
    public func close() { popover?.close() }

    /// The popover, made now with `make`'s view when it was not (then `configure` wires it once),
    /// showing what was kept.
    public func made(_ make: () -> HomeChiefSettingsView, configure: (HomeChiefSettingsView) -> Void) -> HomeChiefSettingsPopover {
        if let popover { return popover }
        let view = make()
        let popover = HomeChiefSettingsPopover(content: view)
        self.popover = popover
        configure(view)
        view.setHost(place: host.place, switchTo: host.switchTo)
        view.setName(name)
        view.pictureStore = pictureStore
        if let avatar { view.setAvatar(picture: avatar.picture, text: avatar.text) }
        return popover
    }

    public func setHost(_ line: HomeChiefHostLine) {
        host = line
        view?.setHost(place: line.place, switchTo: line.switchTo)
    }

    public func setName(_ text: String) {
        name = text
        view?.setName(text)
    }

    public func setAvatar(picture: NSImage?, text: String?) {
        avatar = (picture, text)
        view?.setAvatar(picture: picture, text: text)
    }

    public func setPictureStore(_ store: (avatars: HomeChiefAvatars, chief: String)?) {
        pictureStore = store
        view?.pictureStore = store
    }

    /// Calls `onChange` when the picture `read` gives (a Chief's picked character or upload) differs from
    /// the one this card last saw (the first read only records it); a new call replaces the last follow.
    public func followPicture(_ read: @escaping @MainActor @Sendable () -> URL?, onChange: @escaping @MainActor () -> Void) {
        pictureWatch?.cancel()
        // task-owner: lives until the next follow or this card goes (deinit cancels it); event-driven (Observation)
        pictureWatch = Task { [weak self] in
            for await picture in ObservationStream(read) {
                guard let self, !Task.isCancelled else { return }
                let seen = shownPicture
                shownPicture = .some(picture)
                if let seen, seen != picture { onChange() }
            }
        }
    }
}
