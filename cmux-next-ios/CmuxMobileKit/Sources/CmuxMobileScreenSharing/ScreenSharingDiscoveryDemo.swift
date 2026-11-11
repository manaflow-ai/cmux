#if os(iOS) && DEBUG
public import CmuxDeviceHub
import Foundation

/// DEBUG: Screen Sharing's discovery states without a hub, so a simulator recording
/// shows the loading state (CMUX-13). `-cmux-mobile-screen-sharing-demo MODE`:
/// - `finding`: finding forever;
/// - `found`: finding for a few seconds, then two Macs;
/// - `empty`: finding for a few seconds, then no Macs;
/// - `failed`: the hub can't be reached.
/// The clock starts when the page appears (`start()`), and Try Again or pull to
/// refresh replays it.
extension ScreenSharingService {
    enum DemoMode: String, CaseIterable, Sendable {
        case finding, found, empty, failed
    }

    /// How long a demo stays in "finding" before its answer.
    static let demoFindingTime: Duration = .seconds(5)

    /// The mode named by the launch arguments, if any.
    public static func demoMode(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        guard let index = arguments.firstIndex(of: "-cmux-mobile-screen-sharing-demo"), index + 1 < arguments.count,
              DemoMode(rawValue: arguments[index + 1]) != nil else { return nil }
        return arguments[index + 1]
    }

    /// Puts this service in the demo `name` (one of `DemoMode`); an unknown name does nothing.
    public func useDemo(_ name: String) {
        guard let mode = DemoMode(rawValue: name) else { return }
        demoMode = mode
        demoDiscovery = .finding
        demoMacs = []
    }

    func runDemo(_ mode: DemoMode) {
        demoTask?.cancel()
        demoMacs = []
        if mode == .failed {
            demoDiscovery = .failed(String(localized: "The network connection was lost."))
            return
        }
        demoDiscovery = .finding
        guard mode != .finding else { return }
        // task-owner: one DEBUG demo answer after a fixed delay (a recording, not synchronization)
        demoTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.demoFindingTime) } catch { return }
            guard let self else { return }
            if mode == .found {
                demoMacs = [
                    HubDevice(id: "demo-mbp", name: "Aziz's MacBook Pro", platform: .macos, macScreenShared: true, online: true),
                    HubDevice(id: "demo-studio", name: "Studio", platform: .macos, online: false),
                ]
            }
            demoDiscovery = .listed
        }
    }
}
#endif
