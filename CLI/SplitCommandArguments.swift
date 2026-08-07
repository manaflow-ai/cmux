/// Parsed targeting and direction values shared by split-producing CLI commands.
struct SplitCommandArguments {
    let workspace: String?
    let panel: String?
    let surface: String?
    let focus: String?
    let window: String?
    let direction: String
}
