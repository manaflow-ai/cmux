actor WorkspaceGroupSystemIconCatalogStore {
    static let shared = WorkspaceGroupSystemIconCatalogStore()

    private var loadedCatalog: WorkspaceGroupSystemIconCatalog?

    func catalog() async -> WorkspaceGroupSystemIconCatalog {
        if let loadedCatalog {
            return loadedCatalog
        }
        let loadedCatalog = await WorkspaceGroupSystemIconCatalog.load()
        self.loadedCatalog = loadedCatalog
        return loadedCatalog
    }
}
