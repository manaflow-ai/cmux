/// Retains only the classified terminal cause shared by connection observers.
actor CmxIrohConnectionCloseAttributionStore {
    private var attribution: CmxIrohConnectionCloseAttribution?

    func record(
        cause: String
    ) -> CmxIrohConnectionCloseAttribution {
        record(CmxIrohConnectionCloseAttribution.classify(cause))
    }

    func record(
        _ classified: CmxIrohConnectionCloseAttribution
    ) -> CmxIrohConnectionCloseAttribution {
        if let attribution {
            return attribution
        }
        attribution = classified
        return classified
    }

    func current() -> CmxIrohConnectionCloseAttribution? {
        attribution
    }
}
