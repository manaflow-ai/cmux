import Foundation
#if os(iOS)
import QuartzCore
import UIKit
#endif

/// Runs work at the next display frame: live input that arrives between two frames is applied
/// once, at the frame, instead of once per event (a busy Mac sends hundreds of events a second;
/// the screen can show at most one state per refresh). A one-shot display link on iOS; on a host
/// without a display (macOS `swift test`), the next main-actor turn.
@MainActor
final class NextDisplayFrame: NSObject {
    /// Schedules `work` for the next frame. Callers coalesce: they schedule once and gather
    /// what arrives until it runs.
    static func schedule(_ work: @escaping @MainActor () -> Void) {
        #if os(iOS)
        // A display link does not tick in the background or on a locked screen; a link to the
        // Mac stays up there, so its updates go on at the next main-actor turn.
        guard UIApplication.shared.applicationState != .background else {
            Task { @MainActor in work() }
            return
        }
        let frame = NextDisplayFrame(work)
        let link = CADisplayLink(target: frame, selector: #selector(tick(_:)))
        frame.link = link
        waiting.append(frame)
        observeBackground()
        link.add(to: .main, forMode: .common)
        #else
        Task { @MainActor in work() }
        #endif
    }

    private var work: (@MainActor () -> Void)?

    private init(_ work: @escaping @MainActor () -> Void) {
        self.work = work
    }

    #if os(iOS)
    /// Frames scheduled and not yet run: going to the background runs them, since their links
    /// stop ticking until the app is active again.
    private static var waiting: [NextDisplayFrame] = []
    private static var backgroundObserver: (any NSObjectProtocol)?
    private var link: CADisplayLink?

    private static func observeBackground() {
        guard backgroundObserver == nil else { return }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let frames = waiting
                for frame in frames { frame.run() }
            }
        }
    }

    /// The link holds its target until invalidated: one tick, then both go.
    @objc private func tick(_ link: CADisplayLink) {
        run()
    }

    private func run() {
        link?.invalidate()
        link = nil
        Self.waiting.removeAll { $0 === self }
        let work = work
        self.work = nil
        work?()
    }
    #endif
}
