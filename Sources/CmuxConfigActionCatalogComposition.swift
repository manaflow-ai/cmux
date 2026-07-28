/// Groups action-catalog process and read-limit state so the app can share one
/// injected instance across every window while direct construction stays isolated.
struct CmuxConfigActionCatalogComposition: Sendable {
    let rawReader: any CmuxConfigActionCatalogRawReading
    let readCoordinator: CmuxConfigActionCatalogReadCoordinator

    init(
        processQuarantine: CmuxConfigActionCatalogProcessQuarantine =
            CmuxConfigActionCatalogProcessQuarantine(),
        readCoordinator: CmuxConfigActionCatalogReadCoordinator =
            CmuxConfigActionCatalogReadCoordinator()
    ) {
        self.rawReader = CmuxConfigActionCatalogProcessReader(
            quarantine: processQuarantine
        )
        self.readCoordinator = readCoordinator
    }
}
