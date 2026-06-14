import AppKit
import Foundation

/// Cross-device "active workspace" mirror.
///
/// When Rod moves between the desktop (mac-desktop, the always-on hub) and the
/// laptop, the sidebar set and the Claude tmux sessions already lockstep; the one
/// thing that didn't carry over was *which workspace is selected*. This keeps that
/// in sync so picking up on the other Mac lands on the same workspace.
///
/// This type only ever touches two LOCAL files under Application Support/cmux/.
/// The transport half (shipping them to/from the hub baton
/// `mac-desktop:~/.claude/cmux-active.json`) lives in `cmux-active-syncd` in the
/// Setup repo — no networking in the app.
///
///   active-out.json  — we WRITE `{ "dir": <realpath>, "ts": <ms> }` when the
///                      selected workspace changes *while this app is frontmost*.
///   active-in.json   — the daemon WRITES the newest baton from the OTHER Mac;
///                      we watch the directory and select the matching workspace.
///
/// Conflict model: only the frontmost machine publishes (`NSApp.isActive`), so the
/// Mac you're using is the sole author and the one you walked away from only
/// follows. Cross-machine identity is the workspace **directory** (canonicalised),
/// never the UUID — UUIDs are per-machine.
@MainActor
final class ActiveWorkspaceMirror {
    static let shared = ActiveWorkspaceMirror()

    private let supportDir: URL?
    private var outURL: URL? { supportDir?.appendingPathComponent("active-out.json", isDirectory: false) }
    private var inURL: URL? { supportDir?.appendingPathComponent("active-in.json", isDirectory: false) }

    /// Last directory we PUBLISHED. Guards the echo: when we apply an inbound
    /// baton for dir D we set this to D, so the focus notification that the apply
    /// triggers (posted async — see TabManager.selectedTabId.didSet) is suppressed
    /// regardless of timing.
    private var lastWrittenDir: String?
    /// Last directory we APPLIED from inbound (skip redundant re-selects).
    private var lastAppliedDir: String?
    /// mtime high-water of active-in.json so we apply each baton once.
    private var lastInMTime: TimeInterval = 0
    /// Suppress publishing until the initial inbound sync settles, so a stale
    /// launch-restored selection can't clobber the hub baton before the fresh one
    /// arrives over ssh. Enabled by the first applied baton or a short grace timer.
    private var publishingEnabled = false

    private let watchQueue = DispatchQueue(label: "com.cmuxterm.active-mirror.watch")
    private var dirWatchSource: DispatchSourceFileSystemObject?

    private init() {
        supportDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("cmux", isDirectory: true)
    }

    /// Call once from applicationDidFinishLaunching.
    func start() {
        guard let supportDir else { return }
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectionChanged),
            name: .ghosttyDidFocusTab,
            object: nil
        )
        startInboundWatch()

        // Adopt whatever is already staged (resume where the other Mac left off),
        // then open the publish gate either when a baton lands or after a grace
        // window if none arrives.
        applyInbound()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.publishingEnabled = true
        }
    }

    /// Catch-up apply when this Mac comes to the foreground ("sit-down"). The
    /// directory watch already applies live; this covers anything missed while the
    /// app was inactive.
    func applyPending() {
        applyInbound()
    }

    // MARK: - Publish (selection -> active-out.json)

    @objc private func selectionChanged() {
        // Only the frontmost machine publishes; the follower stays silent.
        guard publishingEnabled, NSApp.isActive else { return }
        guard let ws = AppDelegate.shared?.tabManager?.selectedWorkspace else { return }
        publish(dir: ws.currentDirectory)
    }

    private func publish(dir rawDir: String) {
        guard let outURL else { return }
        let dir = Self.canonical(rawDir)
        guard !dir.isEmpty, dir != lastWrittenDir else { return }
        lastWrittenDir = dir
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        guard let data = try? JSONSerialization.data(withJSONObject: ["dir": dir, "ts": ts]) else { return }
        try? data.write(to: outURL, options: .atomic)
    }

    // MARK: - Apply (active-in.json -> selection)

    /// Watch the cmux support directory (not the file): the daemon writes
    /// active-in.json atomically (temp + rename), which replaces the inode, so a
    /// file-level fd would go stale on every update. The directory fd is stable.
    private func startInboundWatch() {
        guard let supportDir else { return }
        let fd = open(supportDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .rename, .extend],
            queue: watchQueue
        )
        source.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.applyInbound() }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        dirWatchSource = source
    }

    private func applyInbound() {
        guard let inURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: inURL.path),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
              mtime > lastInMTime else { return }
        lastInMTime = mtime

        guard let data = try? Data(contentsOf: inURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawDir = obj["dir"] as? String else { return }
        let dir = Self.canonical(rawDir)
        guard !dir.isEmpty, dir != lastAppliedDir,
              let tabManager = AppDelegate.shared?.tabManager else { return }

        // Already on it — record and open the publish gate, but don't re-select.
        if let cur = tabManager.selectedWorkspace, Self.canonical(cur.currentDirectory) == dir {
            lastAppliedDir = dir
            lastWrittenDir = dir
            publishingEnabled = true
            return
        }
        // Find the workspace by directory; absent on this Mac → no-op.
        guard let match = tabManager.tabs.first(where: { Self.canonical($0.currentDirectory) == dir }) else { return }

        lastAppliedDir = dir
        lastWrittenDir = dir          // pre-empt the echo from this select
        publishingEnabled = true
        tabManager.selectWorkspace(match)
    }

    // MARK: - Helpers

    /// Expand `~` and resolve to a canonical path for cross-machine comparison.
    private static func canonical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return "" }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}
