import AppKit
import CmuxNextControl
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSidebar

#if DEBUG || CMUX_BENCH_HOOKS
/// `debug.windows` and `debug.surfaces` (DEBUG builds; a release router drops
/// every `debug.*` method): the windows the app keeps and what each pane
/// draws. The restore journey (scripts/cmux-next/restore-journey.py) reads
/// both before a quit and after the relaunch.
@MainActor
enum DebugWindowsControl {
    static func methods(_ services: AppServices) -> [ControlMethod] {
        [
            // Chrome text weight vs a stock label (text-weight-e2e.py).
            .async("debug.text_weight") { call in .object(await TextWeightProbe(dark: call.params["dark"]?.boolValue ?? true).measure().mapValues { .number($0) }) },
            // ChromeLabel layout, ink, layer drawing and accessibility vs a stock label (text-weight-e2e.py).
            .mainActor("debug.label_parity") { call in .value(JSONValue(foundation: LabelParityProbe(imageDirectory: call.params["dir"]?.stringValue.map { URL(fileURLWithPath: $0) }).measure().foundation) ?? .null) },
            // Window membership and the window invariants (no window
            // without a workspace), with what each window's record saves.
            .mainActor("debug.windows") { [weak services] _ in
                guard let services, case let windows = services.windows else { return .value(.null) }
                guard case .object(var report) = WindowInvariants.report(windows) else { return .value(.null) }
                report["windows"] = report["windows"]?.arrayValue.map { entries in
                    JSONValue.array(entries.map { entry -> JSONValue in
                        guard case .object(let fields) = entry, let id = fields["id"]?.stringValue else { return entry }
                        return .object(fields.merging(Self.restoreFields(windows, id: id)) { _, new in new })
                    })
                }
                report["displays"] = .number(Double(NSScreen.screens.count))
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

    /// The fields of window `id` its `WindowRecord` saves, as the window shows
    /// them now: `full_screen`, `restores_full_screen` (saved in full screen,
    /// not entered again yet), `sidebar_width` (points; the saved width while
    /// the window has no controller), `sidebar_hidden`, `display` (the display
    /// UUID of the screen the window is on, null with no screen) and
    /// `saved_display` (the registry's, written at each geometry save) and `profile` (the space the
    /// window shows).
    static func restoreFields(_ windows: WindowManager, id: String) -> [String: JSONValue] {
        let controller = windows.controller(for: id), state = windows.states[id]
        let width = controller.map { Double($0.sidebar.model.width) } ?? state?.sidebarWidth
        let hidden = controller.map { $0.sidebar.model.presentation == .hidden } ?? state?.sidebarHidden ?? false
        return [
            "full_screen": .bool(controller?.window?.styleMask.contains(.fullScreen) == true),
            "restores_full_screen": .bool(state?.restoresFullScreen == true),
            "sidebar_width": width.map(JSONValue.number) ?? .null,
            "sidebar_hidden": .bool(hidden),
            "display": controller?.window?.screen.flatMap(WindowPlacementFallback.displayID(of:)).map(JSONValue.string) ?? .null,
            "saved_display": windows.registry.value.window(id)?.display.map(JSONValue.string) ?? .null,
            "profile": state.map { JSONValue.string($0.profileID.rawValue) } ?? .null,
        ]
    }
}
#endif
