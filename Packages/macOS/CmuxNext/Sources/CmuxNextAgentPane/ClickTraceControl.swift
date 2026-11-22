public import CmuxNextControl
import CmuxNextDesign
import CmuxNextSettings
import Foundation

/// `input.clicks` on the app control socket (`cmux app clicks [--limit N]`, every build, Release and Nightly too):
/// where each of the person's last presses went (``ClickTrace``), oldest first. Read-only; it records nothing itself.
/// Here, not in the App (code-quality.md SW14); the App's control service registers it (`AppControl`).
public enum ClickTraceControl {
    public static func method() -> ControlMethod {
        .mainActor(ClickTrace.controlMethod) { call in
            let report = ClickTrace.shared.report(limit: call.params["limit"]?.intValue)
            let json = try? JSONDecoder().decode(CmuxNextSettings.JSONValue.self, from: JSONEncoder().encode(report))
            return .value(json ?? .null)
        }
    }
}
