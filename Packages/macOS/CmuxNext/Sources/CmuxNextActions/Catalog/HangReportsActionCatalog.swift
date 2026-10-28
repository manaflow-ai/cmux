// Opt-in hang reports (plans/cmux-next/hang-reports-DESIGN.md): View Hang Report opens the exact
// JSON of the last report sent (else a preview of what would be sent now) in a cmux file tab. The
// palette, the Settings button and `cmux settings view-hang-report` run this one action. Turning
// reports on and off is the `diagnostics.hangReports` setting (Toggle Setting, `cmux settings set`).
// View Metrics opens every field histogram recorded since launch as JSON in a cmux file tab (chrome://histograms,
// p09-observability task 065). Scripts read the same JSON with `cmux metrics` (the `metrics.snapshot` method), so the
// action has no CLI verb. Both are off until the `metricsView` feature is on.

nonisolated enum HangReportsActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "diagnostics.viewHangReport",
                title: String(localized: "action.diagnostics.viewHangReport", defaultValue: "View Hang Report",
                              table: "HangReportsActions", bundle: .module),
                keywords: ["hang", "lag", "report", "diagnostics", "privacy", "telemetry", "what is sent", "metrickit"],
                category: .settings, symbol: "doc.text.magnifyingglass", surfaces: [.palette],
                cliName: "settings view-hang-report",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "diagnostics.viewMetrics",
                title: String(localized: "action.diagnostics.viewMetrics", defaultValue: "View Metrics",
                              table: "HangReportsActions", bundle: .module),
                keywords: ["metrics", "histograms", "latency", "performance", "diagnostics", "percentiles", "chrome://histograms"],
                category: .settings, symbol: "chart.bar.doc.horizontal", surfaces: [.palette],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
        ]
    }
}
