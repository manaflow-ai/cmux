// The iPhone app's side of live code.
//
// In the iOS Simulator (scripts/live-code/ios-sim.sh): a simulator app is a macOS process, so it
// watches a live folder on the Mac's disk, named by CMUX_LIVE_CODE_DIR (`simctl launch` passes
// SIMCTL_CHILD_CMUX_LIVE_CODE_DIR), and loads the ad hoc patches patch.py drops there.
//
// On an iPhone (scripts/live-code/ios-device.sh): only cmux Dev (bundle dev.cmux.mobile.dev, the
// development-signed try app, cmuxterm-hq docs/design/ios-dev-channels.md) watches, and its folder is
// `Library/LiveCode` in its own data container. The Mac the phone is paired with in Xcode compiles a
// patch for iphoneos, signs it with the Apple Development identity it signed cmux Dev with, and copies
// it there (`devicectl device copy to --domain-type appDataContainer`). iOS itself enforces the
// signature: dyld loads a dylib into a third-party app only when it is signed by the app's own team,
// so no other code reaches the engine. No other bundle id watches on a device, and a Release,
// TestFlight or App Store build compiles none of this (DEBUG only).
//
// Only the app's DEBUG code starts it.
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

    /// cmux Dev's bundle id: the one app that watches a live folder on a device.
    public nonisolated static let deviceBundleID = "dev.cmux.mobile.dev"
    /// Where cmux Dev's live folder is, relative to its data container (ios-device.sh copies there).
    public nonisolated static let deviceFolder = "Library/LiveCode"

    /// In the Simulator, watches the folder CMUX_LIVE_CODE_DIR names; on a device, only cmux Dev
    /// watches, its container's `Library/LiveCode` (``deviceFolder``). Does nothing otherwise.
    public func startFromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment,
                                     bundleID: String? = Bundle.main.bundleIdentifier) {
        guard engine == nil, let url = Self.folderURL(environment: environment, bundleID: bundleID) else { return }
        let folder = LiveFolder(url: url)
        let engine = LiveEngine(folder: folder) { [weak self] generation in
            Task { @MainActor in self?.redraw(generation) }
        }
        self.folder = folder
        self.engine = engine
        Task.detached(priority: .utility) { _ = await engine.start() }
    }

    /// The live folder for this process. On a device: cmux Dev's container folder, and nil for any
    /// other app (CMUX_LIVE_CODE_DIR is not read there). In the Simulator: CMUX_LIVE_CODE_DIR's.
    nonisolated static func folderURL(environment: [String: String], bundleID: String?, onDevice: Bool = isDevice) -> URL? {
        if onDevice {
            guard bundleID == deviceBundleID else { return nil }
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(deviceFolder, isDirectory: true)
        }
        guard let path = environment["CMUX_LIVE_CODE_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    nonisolated private static var isDevice: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
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
