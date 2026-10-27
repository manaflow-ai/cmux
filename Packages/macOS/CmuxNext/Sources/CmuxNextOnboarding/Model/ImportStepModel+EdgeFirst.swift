import CmuxNextBrowserImport

extension ImportStepModel {
    /// Edge leads, stable before its channels (the browser people most
    /// often come from on a work Mac); the rest keep detection order.
    nonisolated static func edgeFirst(_ sources: [BrowserSource]) -> [BrowserSource] {
        let edge: [ImportBrowser] = [.edge, .edgeBeta, .edgeDev, .edgeCanary]
        let edges = sources.filter { edge.contains($0.browser) }
            .sorted { (edge.firstIndex(of: $0.browser) ?? 0) < (edge.firstIndex(of: $1.browser) ?? 0) }
        return edges + sources.filter { !edge.contains($0.browser) }
    }
}
