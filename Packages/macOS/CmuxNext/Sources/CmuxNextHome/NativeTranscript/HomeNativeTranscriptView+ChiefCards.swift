import AppKit
public import CmuxHomeCore
import CmuxNextDesign
import Foundation
public import MessagesLabHome

/// A Chief's cards (cmux issue 25830): Open browser goes to the host; a sign-in card's Add asks for
/// the sign-in in a sheet on this window and hands it to the host's save (the Secure Store). The
/// sheet runs on a private dialog center, so the DEBUG `debug.dialog` verb can neither read nor
/// fill the password; the password goes only to `save`, never into the conversation.
extension HomeNativeTranscriptView {
    static let signInUsernameField = "username"
    static let signInPasswordField = "password"

    /// The host's Secure Store sites (shared by its transcripts): a sign-in card for one shows Added.
    public var chiefCardState: HomeChiefCardState? {
        get { transcript.chiefCardState }
        set { transcript.chiefCardState = newValue }
    }

    /// A browser card's Open browser (a computer card's Open desktop): the target and the card's page URL.
    public var onChiefCardOpen: ((ChiefCard.Target, String?) -> Void)? {
        get { transcript.onChiefCardOpen }
        set { transcript.onChiefCardOpen = newValue }
    }

    /// Turns on a sign-in card's Add: the sheet, then `save(site, username, password)` (the app's
    /// Secure Store, off the main thread); a true answer sends the Added message.
    public func enableChiefSignIn(save: @escaping @MainActor (_ site: String, _ username: String, _ password: String) async -> Bool) {
        transcript.onChiefSignIn = { [weak self] site, _, done in
            guard let self else { return done(false) }
            self.askChiefSignIn(site: site, save: save, done: done)
        }
    }

    private func askChiefSignIn(site: String, save: @escaping @MainActor (String, String, String) async -> Bool,
                                done: @escaping @MainActor (Bool) -> Void) {
        let spec = CmuxDialogSpec(
            title: HomeStrings.chiefSignInTitle(site),
            lines: [HomeStrings.chiefSignInMessage],
            fields: [
                .text(id: Self.signInUsernameField, label: HomeStrings.chiefSignInUsername, initial: "", placeholder: nil, secure: false),
                .text(id: Self.signInPasswordField, label: HomeStrings.chiefSignInPassword, initial: "", placeholder: nil, secure: true),
            ],
            buttons: [.cancel(), CmuxDialogButton(id: "save", title: HomeStrings.chiefSignInSave, role: .default)],
            identifier: "cmux.dialog.chiefSecureStore")
        let scope: CmuxDialogScope = window.map { .window($0) } ?? .app
        // task-owner: one sheet; ends with the person's answer and the save
        Task {
            let answer = await CmuxDialogCenter().present(spec, in: scope)
            guard answer.button == "save",
                  let username = answer.values[Self.signInUsernameField]?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let password = answer.values[Self.signInPasswordField]?.text,
                  !username.isEmpty, !password.isEmpty else { return done(false) }
            done(await save(site, username, password))
        }
    }
}
