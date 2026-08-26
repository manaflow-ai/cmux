/// Selects nearby pages whose diff data should warm before they mount, so a
/// swipe lands on content instead of a placeholder that pops in mid-slide.
struct DiffPagerPrefetchPolicy: Sendable {
    /// How many pages on each side of the selection to keep warm. Must cover
    /// at least the mount window so a newly mounted page finds its data.
    let radius: Int

    init(radius: Int = 2) {
        precondition(radius >= 1)
        self.radius = radius
    }

    /// Paths to warm, nearest first and forward-biased (the next page before
    /// the previous one), excluding the selected page and already-cached paths.
    func prefetchPaths(
        files: [ChangedFileItem],
        selectedIndex: Int,
        cachedPaths: Set<String>
    ) -> [String] {
        guard !files.isEmpty else { return [] }
        let selected = min(max(selectedIndex, 0), files.count - 1)
        var paths: [String] = []
        for distance in 1...radius {
            for index in [selected + distance, selected - distance]
            where files.indices.contains(index) {
                let path = files[index].path
                if !cachedPaths.contains(path) {
                    paths.append(path)
                }
            }
        }
        return paths
    }
}
