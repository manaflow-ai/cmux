#if os(iOS)
/// Routes by stable file identity (repository-relative path), not array
/// position, so a refresh that reorders or removes files cannot retarget an
/// already-pushed diff screen onto a different file.
enum WorkspaceChangesNavigationRoute: Hashable {
    case diff(String)
}
#endif
