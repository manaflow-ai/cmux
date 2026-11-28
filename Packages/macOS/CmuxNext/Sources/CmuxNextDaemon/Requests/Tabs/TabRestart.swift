import Foundation

/// Restarts a terminal tab whose shell ended (`restart-tab`,
/// `tab-restart-v1`, plans/cmux-next/ownership.md 3.2): the daemon starts a
/// new shell for the SAME terminal id, below its previous screen, so the tab,
/// its placement and every reference to the terminal stay. The reply comes
/// when the restart started; the tree shows the tab running again. A tab
/// whose terminal runs is refused with `tab-not-dead`.
public struct RestartTabRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var surface: SurfaceID
        public var terminal: String

        public init(surface: SurfaceID, terminal: String) {
            self.surface = surface
            self.terminal = terminal
        }
    }

    public static let command = "restart-tab"
    public static let requiredCapability: String? = DaemonCapabilities.shared.tabRestart
    public var surface: SurfaceID

    public init(surface: SurfaceID) {
        self.surface = surface
    }
}
