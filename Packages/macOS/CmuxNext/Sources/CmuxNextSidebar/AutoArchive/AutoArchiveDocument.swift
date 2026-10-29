/// The sidebar document as auto-archive uses it: the confirmed records and the archive op. The
/// active ``SidebarDocStore`` conforms; tests pass a fake that applies the mark to its own records.
@MainActor
public protocol AutoArchiveDocument: AnyObject {
    /// The confirmed records (items, their marks and their groups' rules).
    var records: SidebarDocRecords { get }
    /// Archives or unarchives `items` as one undo step titled `title` (the reducer's `archive` and
    /// `unarchive`: groups follow their members).
    func setArchived(_ items: [String], archived: Bool, title: String) throws(SidebarDocSendRefusal)
}
