import CmuxNextControl
import CmuxNextSettings

#if DEBUG
/// `debug.windows` and `debug.surfaces` (DEBUG builds; a release router drops
/// every `debug.*` method): the windows the app keeps and what each pane
/// draws. The restore journey (scripts/cmux-next/restore-journey.py) reads
/// both before a quit and after the relaunch.
@MainActor
enum DebugWindowsControl {
    static func methods(_ services: AppServices) -> [ControlMethod] {
        [
            // Window membership and the window invariants (no window
            // without a workspace).
            .mainActor("debug.windows") { [weak services] _ in
                guard let services, case let windows = services.windows else { return .value(.null) }
                guard case .object(var report) = WindowInvariants.report(windows) else { return .value(.null) }
                // Every workspace the app closed or kept after it lost its
                // last pane, with the cause (EmptyWorkspaceRepair).
                report["emptied_workspaces"] = .array(services.emptyWorkspaces.decisions.map {
                    .object(["key": .string($0.key.rawValue), "cause": .string(String(describing: $0.cause))])
                })
                return .value(.object(report))
            },
            // `text: true` adds each terminal mirror's viewport text, and each
            // terminal pane's `terminal_id` and `host_pid` (SurfaceHostReport).
            .async("debug.surfaces") { [weak services] call in
                let includeText = call.params["text"]?.boolValue == true
                let built: (JSONValue, [SurfaceHostReport.Target])? = await MainActor.run {
                    guard let services else { return nil }
                    return (SurfaceDiagnosticsReport.make(services, includeText: includeText), SurfaceHostReport.targets(services))
                }
                guard let (report, targets) = built else { return .null }
                return SurfaceHostReport.annotate(report, identities: await SurfaceHostReport.identities(targets))
            },
        ]
    }
}
#endif
