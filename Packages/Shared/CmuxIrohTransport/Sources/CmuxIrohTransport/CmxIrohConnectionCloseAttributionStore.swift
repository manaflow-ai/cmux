/// Retains only the classified terminal cause shared by connection observers.
actor CmxIrohConnectionCloseAttributionStore {
    private var tentativeAttribution: CmxIrohConnectionCloseAttribution?
    private var authoritativeAttribution: CmxIrohConnectionCloseAttribution?

    func recordAuthoritative(
        cause: String
    ) -> CmxIrohConnectionCloseAttribution {
        recordAuthoritative(CmxIrohConnectionCloseAttribution.classify(cause))
    }

    func recordAuthoritative(
        _ classified: CmxIrohConnectionCloseAttribution
    ) -> CmxIrohConnectionCloseAttribution {
        if let authoritativeAttribution {
            return authoritativeAttribution
        }
        authoritativeAttribution = classified
        return classified
    }

    func recordTentative(
        _ classified: CmxIrohConnectionCloseAttribution
    ) {
        guard authoritativeAttribution == nil else { return }
        tentativeAttribution = classified
    }

    func current() -> CmxIrohConnectionCloseAttribution? {
        authoritativeAttribution ?? tentativeAttribution
    }
}
