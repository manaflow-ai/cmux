public import AppKit
public import CmuxHomeCore
public import CmuxNextDesign

/// A bare launch's message box in stage 0's first frame (`LaunchShellContent.bare`), before
/// `AppServices` and the real window exist: the Chief's own view over the launch store, taking
/// keys from the first frame. One store and one hold for the launch: the real window's page
/// (``HomeLaunchComposer``) adopts them, so at stage 0's swap nothing moves (the draft and the
/// held sends are already the page's) and the page's box takes the keyboard with the same text.
/// A launch whose real window never mounts that page gives them to the Chief when it is known
/// (``HomeLaunchComposer/claimParked(to:in:)``), so nothing typed in stage 0 is dropped.
@MainActor
public final class HomeLaunchEarly {
    /// This launch's, once stage 0 asked for it; nil after a page adopted it or the Chief took it.
    public private(set) static var current: HomeLaunchEarly?
    /// The one a page adopted, until that page's box took the keyboard (``boxIsUp()``).
    private static var adopted: HomeLaunchEarly?

    public let store: HomeStore
    public let hold: LaunchChiefHold
    /// Stage 0's content: the Chief view in a container that gives its box the keyboard in the window.
    let view: NSView
    /// Stage 0's swap waits for this (`LaunchShellContent.bareReady`) until Home's page is up.
    private var ready: (@MainActor () -> Void)?
    private var isUp = false

    private init(title: String, frame: CGRect, makeView: (HomeStore) -> NSView) {
        hold = LaunchChiefHold()
        // The signed-in person is not known before `AppServices`: a local me, as the provisional
        // Chief is local; the held sends go to the real Chief under their keys either way.
        let me = Participant(id: ParticipantID("me"), kind: .human, displayName: "")  // the view's `me` too
        store = HomeStore(source: HomeLaunchChiefSource(me: me, title: title, hold: hold))
        store.start()
        let chief = makeView(store)
        HomeNativeTranscriptView.first(in: chief)?.holdsChiefFace = true
        view = KeyboardOnWindow(content: chief, frame: frame)
    }

    /// Stage 0 (`shell`) shows a bare launch's message box: the Chief's view over the launch
    /// store, its box taking keys from the first frame. `mark` gets the box's focus marks
    /// (`window_usable` when its window is key), as Home's page in the real window marks them.
    public static func attach(_ shell: LaunchShell, title: @escaping @MainActor () -> String,
                              mark: @escaping @MainActor (String) -> Void) -> LaunchShell {
        shell.content.bare = { frame, _ in
            let early = HomeLaunchEarly(title: title(), frame: frame) { store in
                HomeNativeTranscriptView(store: store, conversation: HomeLaunchChiefSource.conversation, me: ParticipantID("me"),
                                         composerFocused: { mark($0.window?.isKeyWindow == true ? "window_usable" : "home.composer_focused_not_key") })
            }
            current = early
            mark("home.launch_early")
            return early.view
        }
        shell.content.bareReady = { ready in
            guard let early = current ?? adopted, !early.isUp else { return ready() }
            early.ready = ready
        }
        // The page has the store already, or the Chief takes it when known: only the view goes.
        shell.content.handoff = { view in view.removeFromSuperview() }
        return shell
    }

    /// Home's message box in the real window took the keyboard (Home's page, the provisional one
    /// or the Chief's): stage 0 swaps to it. Every focus calls this; only the first after an adopt counts.
    public static func boxIsUp() {
        adopted?.pageIsUp()
        adopted = nil
    }

    private func pageIsUp() {
        isUp = true
        let ready = ready
        self.ready = nil
        ready?()
    }

    /// The real window's page takes the launch's store and hold (once).
    static func adopt() -> HomeLaunchEarly? {
        defer { current = nil }
        adopted = current
        return current
    }

    /// No page took the launch and the Chief is `chief`: its draft and held sends go to it in `home`.
    static func giveToChief(_ chief: ConversationID, in home: HomeStore) {
        guard let early = adopt() else { return }
        adopted = nil
        HomeLaunchComposer.handOff(early.store, hold: early.hold, to: chief, store: home)
        early.pageIsUp()
        early.store.stop()
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
