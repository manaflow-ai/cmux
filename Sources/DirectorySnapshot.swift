/// Immutable per-directory snapshot consumed by `SectionPopoverView` for
/// empty-query scrolling. All entries are merged across the three agent
/// sources and sorted by `modified` desc. The popover slices this array
/// in-memory to page, so scrolling fires zero store/disk calls.
struct DirectorySnapshot: Sendable {
    let cwd: String  // "" represents the unknown-folder bucket
    let entries: [SessionEntry]
    let errors: [String]
}
