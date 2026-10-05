@testable import CmuxNextAgentPane

/// The daemon's answer for acpmux's Claude row (cmux-tui/crates/acpmux/src/web_modes.rs
/// `ASKING_MODES`), for tests that have no daemon socket. The host never copies the table: in the
/// app it reads `_acpmux/web_modes`, and without that answer it asks the user for every mode.
enum AcpmuxAskingModesFake {
    static let claude: @MainActor (_ sessionId: String?, _ mode: String) async -> Bool? = { _, mode in
        ["default", "plan"].contains(mode)
    }
}
