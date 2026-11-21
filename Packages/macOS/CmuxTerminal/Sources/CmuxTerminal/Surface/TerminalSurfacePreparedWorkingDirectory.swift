/// The result of opening a runtime working directory off the main actor.
struct TerminalSurfacePreparedWorkingDirectory: Equatable, Sendable {
    let path: String
    let isOpenable: Bool
}
