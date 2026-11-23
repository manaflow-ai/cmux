#if DEBUG
import CmuxMobileDesign
import UIKit

/// AnimationFrameBenchUITests posts these marks across processes, the same
/// Darwin notification transport as TerminalScrollBench. The recorder belongs
/// to the bench so a feed or terminal window cannot end a UI action's sample.
@MainActor
enum AnimationFrameBench {
    private static let prefix = "dev.cmux.mobile.animationframe."
    private static let recorder = FrameIntervalLog()
    private static var activeLabel: String?

    static func installIfRequested() {
        guard FrameLogSwitch.isEnabled,
              let labels = ProcessInfo.processInfo.environment["CMUX_ANIMATION_BENCH_LABELS"] else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for label in Set(labels.split(separator: ",")) {
            for mark in ["begin", "end"] {
                let name = "\(prefix)\(mark).\(label)"
                CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                    guard let name = name?.rawValue as String? else { return }
                    Task { @MainActor in AnimationFrameBench.receive(name) }
                }, name as CFString, nil, .deliverImmediately)
            }
        }
    }

    private static func receive(_ name: String) {
        let parts = name.dropFirst(prefix.count).split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return }
        let label = String(parts[1])
        if parts[0] == "begin" {
            guard activeLabel == nil else { return }
            activeLabel = label
            recorder.begin(label)
        } else {
            guard activeLabel == label else { return }
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            recorder.end(displayMaximumHz: scene?.screen.maximumFramesPerSecond)
            FrameLogFile.flush()
            activeLabel = nil
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                            CFNotificationName((name + ".ack") as CFString), nil, nil, true)
    }
}
#endif
