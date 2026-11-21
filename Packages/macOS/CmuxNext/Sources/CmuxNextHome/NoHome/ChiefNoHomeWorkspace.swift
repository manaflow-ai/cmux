#if DEBUG
/// DEBUG ONLY: a workspace in the no-Home prototype: its name, branch and the last terminal lines it shows.
struct ChiefNoHomeWorkspace: Identifiable, Hashable {
    var id: String
    var name: String
    var branch: String
    var lines: [String]
}
#endif
