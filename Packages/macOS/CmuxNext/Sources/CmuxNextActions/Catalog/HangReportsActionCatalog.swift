// Opt-in hang reports (plans/cmux-next/hang-reports-DESIGN.md): View Hang Report opens the exact
// JSON of the last report sent (else a preview of what would be sent now) in a cmux file tab. The
// palette, the Settings button and `cmux settings view-hang-report` run this one action. Turning
// reports on and off is the `diagnostics.hangReports` setting (Toggle Setting, `cmux settings set`).

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
        ]
    }
}
