/// The Toast Playground's samples: one toast of every kind the app shows. English developer text, as every
/// Debug Settings sample is.
struct CmuxToastPlaygroundSamples {
    /// A hint, a notice with Don't Show Again, an Undo, a Details, an error and a prompt with two actions.
    static let kinds: [CmuxToast] = [
        CmuxToast(id: "playground.hint", message: "Option or Shift + drag selects text"),
        CmuxToast(id: "playground.notice", message: "Copied the link to “Release notes”", detail: "https://cmux.com/changelog", tone: .success),
        CmuxToast(id: "playground.undo", message: "Closed “zsh”", action: .undo()),
        CmuxToast(id: "playground.details", message: "Couldn’t save “notes.md”: the disk is full",
                  detail: "fs.no_space: write(2) returned ENOSPC", action: .details("Details"), tone: .warning),
        CmuxToast(id: "playground.error", message: "No room for another split", tone: .error),
        CmuxToast(id: "playground.prompt", message: "A server update is ready", detail: "cmux-tui 0.214 restarts your sessions in place",
                  action: CmuxToast.Action(title: "Restart"), secondaryAction: CmuxToast.Action(title: "Later"),
                  duration: CmuxToast.untilClosed),
    ]

    /// What Fire it shows, as real toasts in the window: a hint, an Undo and a prompt (the stack's three).
    static let fired: [CmuxToast] = [kinds[0], kinds[2], kinds[5]]
}
