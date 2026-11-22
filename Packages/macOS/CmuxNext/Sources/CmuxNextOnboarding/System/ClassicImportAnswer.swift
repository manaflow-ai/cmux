/// How the person answered the classic import preview (`ClassicImportPreview`).
public nonisolated enum ClassicImportAnswer: Equatable, Sendable {
    /// Import pressed.
    case accepted
    /// Cancel pressed (or Escape): the launch's run records it and stops asking.
    case declined
    /// Nobody answered: the window closed under the dialog or the app quit. The next launch asks again.
    case unanswered
}
