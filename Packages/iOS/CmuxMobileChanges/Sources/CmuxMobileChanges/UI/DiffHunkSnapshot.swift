struct DiffHunkSnapshot: Identifiable, Equatable {
    let index: Int
    let hunk: DiffHunk

    var id: Int { index }
}
