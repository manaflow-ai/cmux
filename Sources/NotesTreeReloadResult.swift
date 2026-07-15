import Foundation

/// Output of an off-main ``NotesTreeStore`` reload pass: the rebuilt tree plus
/// the directories the store should keep file watchers on.
struct NotesTreeReloadResult: Sendable {
    var nodes: [NotesTreeNode]
    var watchedDirs: Set<String>
}
