// The iPhone app's side of live code, in the iOS Simulator (scripts/live-code/ios-sim.sh): a
// simulator app is a macOS process, so it watches a live folder on the Mac's disk, named by
// CMUX_LIVE_CODE_DIR (`simctl launch` passes SIMCTL_CHILD_CMUX_LIVE_CODE_DIR), and loads the ad hoc
// patches patch.py drops there. Only the app's DEBUG code starts it.
//
// The redraw: SwiftUI calls a view's `body` again only when something it read changed, so a patched
// `body` would not run until then. After each change the root (`liveCodeRedraw(_:)`) takes a new
// identity, and SwiftUI builds the whole tree again with the new code. Its state below the root
// starts over, as after a relaunch, but the process, its connections and the app's models stay.
// Only a DEBUG build has it (LiveEngine.swift): shipped iPhone builds compile none of it.
#if os(iOS) && DEBUG
import Foundation
import Observation
import SwiftUI
import UIKit

/// The live folder's watcher and the generation the root view is keyed by. The app makes one at its
/// composition root and passes it to `liveCodeRedraw(_:)`.
@MainActor
@Observable
public final class LiveCodeRedraw {
    /// Starts at 0 and grows by one per applied or undone patch.
    public private(set) var generation = 0
    @ObservationIgnored private var engine: LiveEngine?
    @ObservationIgnored private var folder: LiveFolder?

    public init() {}

    /// Watches the folder CMUX_LIVE_CODE_DIR names; does nothing without it.
    public func startFromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard engine == nil, let path = environment["CMUX_LIVE_CODE_DIR"], !path.isEmpty else { return }
        let folder = LiveFolder(url: URL(fileURLWithPath: path, isDirectory: true))
        let engine = LiveEngine(folder: folder) { [weak self] generation in
            Task { @MainActor in self?.redraw(generation) }
        }
        self.folder = folder
        self.engine = engine
        Task.detached(priority: .utility) { _ = await engine.start() }
    }

    /// The root takes a new identity, and every window's UIKit views lay out and draw again. Logs
    /// when the frame after it is committed, so a harness can time a save to the screen.
    private func redraw(_ generation: Int) {
        self.generation = generation
        for scene in UIApplication.shared.connectedScenes {
            guard let windows = (scene as? UIWindowScene)?.windows else { continue }
            for window in windows {
                Self.invalidate(window)
            }
        }
        guard let folder else { return }
        DispatchQueue.main.async {
            let line = "live code: redrawn generation=\(generation) at=\(Date().timeIntervalSince1970)"
            Task.detached(priority: .utility) { folder.append(line) }
        }
    }

    private static func invalidate(_ view: UIView) {
        view.setNeedsLayout()
        view.setNeedsDisplay()
        for subview in view.subviews { invalidate(subview) }
    }
}

private struct LiveCodeRedrawModifier: ViewModifier {
    let live: LiveCodeRedraw

    func body(content: Content) -> some View {
        content.id(live.generation)
    }
}

extension View {
    /// The live code root: rebuilt with the new code after each patch (LiveCodeRedraw). Put it on
    /// the app's root view, in DEBUG code only.
    public func liveCodeRedraw(_ live: LiveCodeRedraw) -> some View {
        modifier(LiveCodeRedrawModifier(live: live))
    }
}
#endif
