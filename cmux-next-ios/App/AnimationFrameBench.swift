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
    private static var firstTick: FrameClock.Token?
    private static let summaryProbe: UIView = {
        let view = UIView(frame: CGRect(x: 1, y: 1, width: 2, height: 2))
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = true
        view.accessibilityTraits = .staticText
        view.accessibilityIdentifier = "debug.animationFrameSummary"
        view.accessibilityLabel = "Animation frame summary"
        return view
    }()

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
            // The first tick establishes the delta's starting timestamp and CPU
            // sample. The gesture can start as soon as that callback has run.
            firstTick = FrameClock.shared.subscribe { _ in
                guard let token = firstTick else { return }
                FrameClock.shared.unsubscribe(token)
                firstTick = nil
                acknowledge(name)
            }
        } else {
            guard activeLabel == label else { return }
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            if let stats = recorder.end(displayMaximumHz: scene?.screen.maximumFramesPerSecond),
               let data = try? JSONEncoder().encode(stats),
               let window = scene?.windows.first(where: \.isKeyWindow) {
                // A presented sheet owns its accessibility tree. Put the probe
                // in the front controller each time, after the window closes.
                var controller = window.rootViewController
                while let presented = controller?.presentedViewController { controller = presented }
                summaryProbe.accessibilityValue = String(decoding: data, as: UTF8.self)
                (controller?.view ?? window).addSubview(summaryProbe)
            }
            FrameLogFile.flush()
            activeLabel = nil
            acknowledge(name)
        }
    }

    private static func acknowledge(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                            CFNotificationName((name + ".ack") as CFString), nil, nil, true)
    }
}
#endif
