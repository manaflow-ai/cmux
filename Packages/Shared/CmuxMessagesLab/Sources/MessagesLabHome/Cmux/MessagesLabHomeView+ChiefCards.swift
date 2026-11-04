import AppKit
import CmuxHomeCore

/// A Chief's cards (cmux issue 25830): what their buttons ask of the host.
extension MessagesLabHomeView {
    /// A browser card's Open browser (or a computer card's Open desktop): the host opens `target`
    /// (the browser right of the Home chat, or a Cloud machine's desktop); the card's page URL comes
    /// with it. Nil: the button opens nothing.
    public var onChiefCardOpen: ((ChiefCard.Target, String?) -> Void)? {
        get { projection.onChiefCardOpen }
        set { projection.onChiefCardOpen = newValue }
    }

    /// A sign-in card's Add for `site`: the host asks for the sign-in (a sheet on the window) and saves
    /// it in the Secure Store, then calls `done(true)`; the chat then sends "I added my sign-in for
    /// <site> to the Secure Store." as the person. `done(false)`: cancelled or not saved, nothing is sent.
    public var onChiefSignIn: ((_ site: String, _ url: String?, _ done: @escaping @MainActor (Bool) -> Void) -> Void)? {
        get { projection.onChiefSignIn }
        set { projection.onChiefSignIn = newValue }
    }

    /// The host's Secure Store sites (one ``HomeChiefCardState`` for all its transcripts): a sign-in
    /// card for one of them shows Added, and a change redraws the shown cards. Nil: none shows Added.
    public var chiefCardState: HomeChiefCardState? {
        get { projection.cardState }
        set { projection.cardState = newValue }
    }
}
