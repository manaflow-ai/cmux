public import CmuxNextCompat
public import CmuxNextControl
public import CmuxNextTrace
public import Foundation

/// What the app's last-hang bundles (``LastHangBundles``, task p09-observability-125) read from the composition root.
/// A bundle copies the black boxes of the app's trace folder (the app's own, and the daemon's and its children's,
/// task 095), of this session's terminal hosts and of every holder's `<socket>.trace` folder: the folders
/// ``RustDiagnosticsLog/Roots`` names for the same processes' hang logs.
///
/// ```swift
/// let bundles = services.makeLastHangBundles()?.attached(to: watchdog)
/// ```
@MainActor
public protocol LastHangHost: AnyObject {
    /// The app process's black box; nil in a process that is not the real app (tests that build the services).
    var lastHangBlackBox: TraceBlackBox? { get }
    /// The app's Rust log and trace folders.
    var lastHangRoots: RustDiagnosticsLog.Roots { get }
    /// The blocking-work lanes the copies run on (`.files`).
    var lastHangWork: any MayBlockRunner { get }
    /// Whether hangs make bundles (the `lastHangBundle` feature).
    var capturesLastHangs: Bool { get }
}

extension LastHangHost {
    /// New bundles in the black box's folder; nil with no black box. The watchdog's triggers and `trace.blackbox`
    /// each make their own: only the triggers' copy has a rate limit to share.
    public func makeLastHangBundles() -> LastHangBundles? {
        guard let blackBox = lastHangBlackBox else { return nil }
        let roots = lastHangRoots
        let folders = [blackBox.directory, roots.terminalHostTraceDirectory.path]
        let holders = roots.holderDirectory.path
        return LastHangBundles(traceDirectory: blackBox.directory,
                               ringFolders: { permit in folders + LastHangBundles.folders(in: holders, suffix: ".trace", permit) },
                               ownRing: (blackBox.ring, TraceRingFile.fileName(role: .app, pid: blackBox.pid)),
                               work: lastHangWork, capturesHangs: capturesLastHangs)
    }
}

extension RustDiagnosticsLog.Roots {
    /// The owner's sessions folder: the build's `CMUX_TUI_STATE_DIR` (`DaemonLauncher.appNames`) or cmux-tui's
    /// default. Its parent is the owner's state root.
    public static func ownerSessionsDirectory(stateDirectory: URL?) -> URL {
        stateDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/cmux-tui/sessions", directoryHint: .isDirectory)
    }
}
