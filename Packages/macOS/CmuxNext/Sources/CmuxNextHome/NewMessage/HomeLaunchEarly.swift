public import AppKit
public import CmuxHomeCore
public import CmuxNextDesign
import CmuxNextHomeModel

/// A bare launch's message box in stage 0's first frame (`LaunchShellContent.bare`), before
/// `AppServices` and the real window exist: the Chief's own view over the launch store, taking
/// keys from the first frame. One per launch, made in `main` and kept on stage 0's content
/// (`LaunchShellContent.owner`), from where the app gives it to Home (`HomeService.launchEarly`).
/// One store and one hold for the launch: the real window's page (``HomeLaunchComposer``) adopts
/// them, so at stage 0's swap nothing moves (the draft and the held sends are already the page's)
/// and the page's box takes the keyboard with the same text. A launch whose real window never
/// mounts that page gives them to the Chief when it is known, and a quit before either keeps them
/// as Home's draft of the launch conversation: nothing typed in stage 0 is dropped.
@MainActor
public final class HomeLaunchEarly {
    /// Stage 0's box, once stage 0 asked for it; nil again after a page or the Chief took it.
    public private(set) var box: Box?
    /// The box a page took, until that page's box took the keyboard (``boxIsUp()``).
    private var adopted: Box?
    /// Stage 0's swap waits for this (`LaunchShellContent.bareReady`) until Home's box is up.
    private var ready: (@MainActor () -> Void)?
    private var isUp = false
    private let title: @MainActor () -> String
    private let panels: @MainActor () -> [HomeHeaderPanelItem]
    private let mark: @MainActor (String) -> Void

    /// The launch store and hold behind stage 0's box, and its view.
    @MainActor
    public final class Box {
        public let store: HomeStore
        public let hold: LaunchChiefHold
        /// Stage 0's content: the Chief view in a container that gives its box the keyboard in the window.
        let view: NSView

        init(title: String, frame: CGRect, makeView: (HomeStore) -> NSView) {
            hold = LaunchChiefHold()
            store = HomeStore(source: HomeLaunchChiefSource(me: HomeLaunchEarly.me, title: title, hold: hold))
            store.start()
            let chief = makeView(store)
            HomeNativeTranscriptView.first(in: chief)?.holdsChiefFace = true
            view = KeyboardOnWindow(content: chief, frame: frame)
        }
    }

    /// The signed-in person is not known before `AppServices`: a local me, as the provisional
    /// Chief is local; the held sends go to the real Chief under their keys either way.
    static let me = Participant(id: ParticipantID("me"), kind: .human, displayName: "")

    /// - Parameters:
    ///   - title: The Chief's name (`HomeStrings.chiefName`), read when stage 0 asks.
    ///   - panels: The header toggles a local Chief's page shows, all off (`HomeHeaderPanels.launchItems`).
    ///   - mark: The box's launch marks (`home.launch_early`, and `window_usable` when it takes
    ///     the keyboard in a key window), as Home's page in the real window marks them.
    public init(title: @escaping @MainActor () -> String, panels: @escaping @MainActor () -> [HomeHeaderPanelItem],
                mark: @escaping @MainActor (String) -> Void) {
        self.title = title
        self.panels = panels
        self.mark = mark
    }

    /// Stage 0 (`shell`) shows a bare launch's message box; returns `shell`.
    public func attach(_ shell: LaunchShell) -> LaunchShell {
        shell.content.owner = self
        shell.content.bare = { [weak self] frame, _ in self?.start(frame: frame) }
        shell.content.bareReady = { [weak self] ready in
            guard let self else { return ready() }
            whenUp(ready)
        }
        // The page has the store already, or the Chief takes it when known: only the view goes.
        shell.content.handoff = { view in view.removeFromSuperview() }
        return shell
    }

    /// Stage 0's content for this launch: makes the box and its view.
    func start(frame: CGRect) -> NSView {
        let mark = mark
        let panels = panels()
        let box = Box(title: title(), frame: frame) { store in
            let view = HomeNativeTranscriptView(store: store, conversation: HomeLaunchChiefSource.conversation, me: Self.me.id,
                                                composerFocused: { mark($0.window?.isKeyWindow == true ? "window_usable" : "home.composer_focused_not_key") })
            // What Home's page over this conversation shows at the swap: its header toggles (off), and the
            // first-run panel hidden on a fresh install, where the welcome plays in the chat (HomeHostView).
            view.setHeaderPanels(panels)
            view.welcomesInChat = ChiefIntroStore(defaults: .standard).welcomePending
            return view
        }
        self.box = box
        mark("home.launch_early")
        return box.view
    }

    /// Calls `ready` once Home's box in the real window is up (at once when it is, or when there is
    /// no launch box).
    func whenUp(_ ready: @escaping @MainActor () -> Void) {
        guard box != nil || adopted != nil, !isUp else { return ready() }
        self.ready = ready
    }

    /// Home's message box in the real window took the keyboard (Home's page, the provisional one
    /// or the Chief's): stage 0 swaps to it. Every focus calls this; only the first after an adopt counts.
    public func boxIsUp() {
        guard adopted != nil else { return }
        adopted = nil
        up()
    }

    private func up() {
        isUp = true
        let ready = ready
        self.ready = nil
        ready?()
    }

    /// The real window's page takes the launch's store and hold (once).
    func adopt() -> Box? {
        defer { box = nil }
        adopted = box
        return box
    }

    /// No page took the launch and the Chief is `chief`: its draft and held sends go to it in `home`.
    public func giveToChief(_ chief: ConversationID, in home: HomeStore) {
        guard let box = adopt() else { return }
        adopted = nil
        HomeLaunchComposer.handOff(box.store, hold: box.hold, to: chief, store: home)
        up()
        box.store.stop()
    }

    /// Quit's save step while no page took the box: its held and typed text as `home`'s draft of the
    /// launch conversation, which the next launch's page starts with. The box goes on (a quit can be cancelled).
    public func saveForQuit(in home: HomeStore) {
        guard let box else { return }
        let text = HomeLaunchComposer.keptText(box.store, held: box.hold.heldParts)
        home.setDraft(text, for: HomeLaunchChiefSource.conversation)
    }
}

/// Stage 0's content view: gives the Chief view's message box the keyboard once it is in a window.
private final class KeyboardOnWindow: NSView {
    private let content: NSView

    init(content: NSView, frame: CGRect) {
        self.content = content
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        HomeNativeTranscriptView.first(in: content)?.takeKeyboardOnOpen()
    }
}
