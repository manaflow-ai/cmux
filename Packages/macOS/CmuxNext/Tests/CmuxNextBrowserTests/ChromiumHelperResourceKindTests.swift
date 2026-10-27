import CmuxNextBrowser
import CmuxNextMetrics
import Testing

/// Task 121: each Chromium helper type samples under its process kind's resource histograms.
@Suite struct ChromiumHelperResourceKindTests {
    @Test func everyHelperTypeHasItsResourceKind() {
        let rows: [(ChromiumHelperProcess.Kind, HistogramID.ProcessKind?)] = [
            (.renderer(clientID: 12), .renderer),
            (.extensionRenderer, .renderer),
            (.gpu, .gpu),
            (.network, .utility),
            (.utility, .utility),
            (.other, nil),
        ]
        for (kind, resourceKind) in rows {
            #expect(kind.resourceKind == resourceKind)
        }
    }
}
