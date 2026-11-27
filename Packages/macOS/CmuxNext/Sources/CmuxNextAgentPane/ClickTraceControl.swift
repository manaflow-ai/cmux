public import CmuxNextControl
import CmuxNextDesign
import CmuxNextSettings
import Foundation

/// `input.clicks` on the app control socket (`cmux app clicks [--limit N]`, every build, Release and Nightly too):
/// where each of the person's last presses went in every cmux window (``ClickTrace``), oldest first. Read-only; it records nothing itself.
/// Here, not in the App (code-quality.md SW14); the App's control service registers it (`AppControl`).
public struct ClickTraceControl {
    public init() {}
    public static func method() -> ControlMethod {
        .mainActor(ClickTrace.controlMethod) { call in
            let report = ClickTrace.report(WindowOverlayHost.clickTraces, limit: call.params["limit"]?.intValue)
            // main-actor-ok: the report is at most ClickTrace.capacity (200) presses per window, fewer with `limit`.
            let json = try? JSONDecoder().decode(CmuxNextSettings.JSONValue.self, from: JSONEncoder().encode(report))
            return .value(json ?? .null)
        }
    }
}
