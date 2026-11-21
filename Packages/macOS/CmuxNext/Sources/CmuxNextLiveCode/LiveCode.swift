// Live code in the app: a running cmux NEXT takes new code for its Swift functions without a
// rebuild or a relaunch, as the view shell does (Prototypes/ViewShell/README.md, "Live code"). The
// engine (Packages/Shared/CmuxLiveCode: the live folder, the patch's load and repoint, status and
// log) is the one the iPhone app runs in the iOS Simulator; this file is the macOS app's side: when
// it watches, and every window's redraw after a change. It works only in a live code build
// (scripts/live-code/build.sh).
//
// The app delegate holds the one instance. Debug and bench builds watch, and a live code build of
// a NIGHTLY (CMUX_LIVE_CODE), which loads only patches its own team signed (PatchSignature.swift).
import AppKit
import CmuxLiveCode
import Foundation

extension LiveFolder {
    /// The person's live folder, where `cmux live-code` looks by default.
    static var standard: LiveFolder {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Caches", isDirectory: true)
        return LiveFolder(url: caches.appendingPathComponent("cmux-next/live-code", isDirectory: true))
    }
}

/// The live folder's watcher, as the app delegate holds it.
@MainActor
public final class LiveCode {
    /// Watches the folder CMUX_LIVE_CODE_DIR names.
    public static func fromEnvironment() -> LiveCode {
        let live = LiveCode()
        #if DEBUG || CMUX_BENCH_HOOKS || CMUX_LIVE_CODE
        if let path = ProcessInfo.processInfo.environment["CMUX_LIVE_CODE_DIR"], !path.isEmpty {
            live.watch(LiveFolder(url: URL(fileURLWithPath: path, isDirectory: true)))
        }
        #endif
        return live
    }

    /// Labs > Live Code (`labs.liveCode`, read at launch): with the switch on, watches the person's
    /// live folder (``LiveFolder/standard``), unless CMUX_LIVE_CODE_DIR already named one. Off,
    /// nothing changes.
    public func labsSwitch(_ on: Bool) {
        #if DEBUG || CMUX_BENCH_HOOKS || CMUX_LIVE_CODE
        guard on, engine == nil else { return }
        watch(LiveFolder.standard)
        #endif
    }

    private var engine: LiveEngine?

    /// Swift live mode is on (`cmux live start --swift`): this is a live code build (reload.sh marks
    /// its Info.plist `CMUXLiveCodeBuild`) and it watches a live folder. A normal build with Labs >
    /// Live Code on watches too, but its functions cannot be repointed, so it is not live. It stays on
    /// until the app quits; live mode ends with a restart into the normal build.
    public private(set) var isLive = false
    /// Work waiting for live mode to start (each window's "Live mode" badge), run once when it does.
    private var whenLiveStarts: [@MainActor () -> Void] = []
    private let isLiveCodeBuild = Bundle.main.object(forInfoDictionaryKey: "CMUXLiveCodeBuild") as? Bool == true

    /// Runs `body` now if live mode is on, else once when it starts. Stop condition: it runs at most
    /// once and the list empties when it does; a build that cannot go live keeps nothing.
    public func whenLive(_ body: @escaping @MainActor () -> Void) {
        #if DEBUG || CMUX_BENCH_HOOKS
        guard isLiveCodeBuild else { return }
        if isLive { body() } else { whenLiveStarts.append(body) }
        #endif // a Release build never watches, so nothing waits
    }

    private func watch(_ folder: LiveFolder) {
        // Debug and bench load any patch; any other live code build only its own team's (cmux#13742).
        #if DEBUG || CMUX_BENCH_HOOKS
        let signer: PatchSignature.AppSigner? = nil
        #else
        let signer: PatchSignature.AppSigner? = PatchSignature.runningSigner()
        #endif
        let engine = LiveEngine(folder: folder, signer: signer) { generation in
            Task { @MainActor in LiveCode.redraw(generation: generation, folder: folder) }
        }
        self.engine = engine
        Task.detached(priority: .utility) { [weak self] in
            guard await engine.start() else { return }
            await self?.watching()
        }
    }

    /// The engine watches its folder: in a live code build, live mode is on.
    private func watching() {
        isLive = isLiveCodeBuild
        guard isLive else { return }
        let waiting = whenLiveStarts
        whenLiveStarts = []
        for body in waiting { body() }
    }

    /// Every window's views draw and lay out again: their next `updateLayer`, `draw` and `layout`
    /// run the new code. Logs when, so a harness can time a change to the redraw.
    static func redraw(generation: Int, folder: LiveFolder) {
        for window in NSApp.windows where window.isVisible {
            if let content = window.contentView { invalidate(content) }
            window.displayIfNeeded()
        }
        let line = "live code: redrawn generation=\(generation) at=\(Date().timeIntervalSince1970)"
        Task.detached(priority: .utility) { folder.append(line) }
    }

    private static func invalidate(_ view: NSView) {
        view.needsDisplay = true
        view.needsLayout = true
        for subview in view.subviews { invalidate(subview) }
    }
}
