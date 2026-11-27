public import Foundation

/// Where a file page's file lives (#25581): this Mac's disk, or the machine of the pane the tab
/// opened in. A tab in a Cloud workspace reads, saves and watches the file on the VM, never a
/// file of the same path on this Mac.
@MainActor public protocol FilePageFiles: AnyObject {
    /// The file is on this Mac: its folder's images and links, its git remote, recents, drafts and
    /// the pickers read this Mac's disk. Nothing local is read for a file that is not.
    var isLocal: Bool { get }
    /// The path every grant compares: links resolved on this Mac; `.` and `..` removed elsewhere.
    func canonical(_ url: URL) -> URL
    /// The file's contents and read-only reason (`inWorkspace`: a workspace root contains it).
    func read(_ url: URL, inWorkspace: Bool) async throws(FileOpenFailure) -> FileSnapshot
    /// `cmux.<page>.save`: writes `text` when the file's hash is still `baseHash`.
    func save(_ text: String, to url: URL, baseHash: String?, inWorkspace: Bool) async throws(FileSaveFailure) -> FileSaveResult
    /// A watch of `url`. `onUnavailable` hears the machine go away (its reason) and come back
    /// (nil); this Mac's disk never goes away.
    func watch(_ url: URL, inWorkspace: @escaping () -> Bool, clock: any Clock<Duration>,
               onChange: @escaping (FileSnapshot?) -> Void, onUnavailable: @escaping (String?) -> Void) -> any FilePageWatching
}
