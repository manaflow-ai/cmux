public import CmuxNextCompat
import Darwin
public import Foundation

/// One copy of a cmux bundle on disk, as its Info.plist names it (Leo, 2026-11-08, on a team Mac: "cmux NIGHTLY.app" and
/// a month-older "cmux NIGHTLY 2.app" with the same bundle id sat side by side in /Applications).
public nonisolated struct AppCopy: Equatable, Sendable {
    public var path: String
    public var bundleIdentifier: String?
    /// `CFBundleShortVersionString`.
    public var version: String?
    /// `CFBundleVersion` (monotonic, R78).
    public var build: String?
    /// False when nothing is at ``path`` any more (the copy was moved or deleted while it ran).
    public var exists: Bool

    public init(path: String, bundleIdentifier: String?, version: String?, build: String?, exists: Bool = true) {
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.exists = exists
    }

    /// The copy at `path`, read from its Info.plist (one small file read; call it off the main thread).
    public static func read(path: String) -> AppCopy {
        let data = FileManager.checked.contents(atPath: (path as NSString).appendingPathComponent("Contents/Info.plist"))
        let info = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any]
        return AppCopy(path: path, bundleIdentifier: info?["CFBundleIdentifier"] as? String,
                       version: info?["CFBundleShortVersionString"] as? String, build: info?["CFBundleVersion"] as? String,
                       exists: info != nil || FileManager.checked.fileExists(atPath: path))
    }

    /// Whether this copy's build is newer than `other`'s (numeric `CFBundleVersion`; an unknown build is never newer).
    public func isNewer(than other: AppCopy) -> Bool {
        guard let build else { return false }
        guard let otherBuild = other.build else { return true }
        return KeptVersionStore.isNewer(build, than: otherBuild)
    }

    /// "0.71.0 (4245364216501)", or the build alone, or nil.
    public var versionText: String? {
        switch (version, build) {
        case let (version?, build?): "\(version) (\(build))"
        case let (nil, build?): build
        case let (version?, nil): version
        case (nil, nil): nil
        }
    }
}

/// Where a cmux bundle runs from. A copy macOS translocated (opened from Downloads without being moved) or one on a
/// disk image can never update itself, vanishes at reboot or eject, and is not the copy the user installed; it should
/// not publish itself as the user's `cmux` (``LastAppCLIPointer``) and is offered a move to Applications at launch.
public nonisolated enum AppCopyPlace: Equatable, Sendable {
    /// A writable folder: Applications, ~/Applications, or anywhere else the user put it.
    case installed
    /// App Translocation's randomized read-only mirror (`/private/var/folders/.../AppTranslocation/...`).
    case translocated
    /// A read-only volume, most often the downloaded disk image (its mount point).
    case readOnlyVolume(String)

    /// The place of the bundle at `bundlePath`. `readOnlyMount` answers the mount point of a path on a read-only
    /// volume, else nil (``readOnlyMount(of:)``; injected in tests).
    public static func of(bundlePath: String, readOnlyMount: (String) -> String? = AppCopyPlace.readOnlyMount(of:)) -> AppCopyPlace {
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        if let mount = readOnlyMount(bundlePath) { return .readOnlyVolume(mount) }
        return .installed
    }

    /// Whether a copy here is a passing one (translocated or read-only), not the user's install.
    public var isPassing: Bool { self != .installed }

    /// The mount point of `path` when its volume is mounted read-only (one `statfs`), else nil.
    public static func readOnlyMount(of path: String) -> String? {
        var stats = statfs()
        guard statfs(path, &stats) == 0, stats.f_flags & UInt32(bitPattern: MNT_RDONLY) != 0 else { return nil }
        return withUnsafeBytes(of: stats.f_mntonname) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

/// What a launch from a passing place (``AppCopyPlace``) offers: move this copy to Applications and reopen it there.
public nonisolated enum AppMoveOffer: Equatable, Sendable {
    /// Nothing is at `destination`: copy this bundle there.
    case move(destination: String)
    /// An older copy of the same app is at `destination`: replace it (the old one goes to the Trash).
    case replace(destination: String, installed: AppCopy)
    /// The same or a newer build of the same app is already at `destination`: open that one instead.
    case openInstalled(AppCopy)

    /// The offer for `running` at `place`, given what is at `destination` (`installed`, nil when nothing is there).
    /// Nil when there is nothing to offer: the copy is installed already, or `destination` holds another app (a
    /// different bundle id under the same name), which a move must never replace.
    public static func decide(running: AppCopy, place: AppCopyPlace, destination: String, installed: AppCopy?) -> AppMoveOffer? {
        guard place.isPassing else { return nil }
        guard let installed, installed.exists else { return .move(destination: destination) }
        guard installed.bundleIdentifier == running.bundleIdentifier else { return nil }
        return running.isNewer(than: installed) ? .replace(destination: destination, installed: installed) : .openInstalled(installed)
    }

    /// The folder a move puts the app in: /Applications when it is writable, else ~/Applications.
    public static func applicationsFolder(writable: (String) -> Bool = { FileManager.checked.isWritableFile(atPath: $0) },
                                          home: String = NSHomeDirectory()) -> String {
        writable("/Applications") ? "/Applications" : (home as NSString).appendingPathComponent("Applications")
    }
}

/// What the running copy says when a second copy of it is opened (``SingleInstanceHandoff``). Before this, the second
/// copy handed off silently, so a person who opened a newer download kept using the older build without knowing.
public nonisolated enum SecondCopyNotice: Equatable, Sendable {
    /// The same copy was opened again (a Dock click, a URL): hand off without a word, as before.
    case none
    /// Another copy was opened: say which copy and version kept running and which was opened. `offersSwitch` when the
    /// opened copy is newer, or when the running copy's bundle is gone from disk (moved or deleted while it ran).
    case tell(running: AppCopy, opened: AppCopy, offersSwitch: Bool)

    public static func decide(running: AppCopy, opened: AppCopy) -> SecondCopyNotice {
        let samePath = Self.normalized(running.path) == Self.normalized(opened.path)
        if samePath, running.exists, running.build == opened.build { return .none }
        return .tell(running: running, opened: opened, offersSwitch: !running.exists || opened.isNewer(than: running))
    }

    private static func normalized(_ path: String) -> String {
        URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

public nonisolated extension AppMoveOffer {
    /// Where the app opens after the offer runs.
    var destination: String {
        switch self {
        case .move(let destination), .replace(let destination, _): destination
        case .openInstalled(let installed): installed.path
        }
    }

    /// Runs the offer for the bundle at `running` (off the main thread: a whole-bundle copy). A move or replace
    /// copies the bundle beside the destination under a hidden name, clears its quarantine (so macOS does not
    /// translocate the copy again), then renames it into place; a replaced copy is moved aside first and goes to
    /// the Trash only after the new one is in place, else it is put back. Returns the bundle to open.
    func perform(running: URL, files: CheckedFileManager = FileManager.checked,
                 trash: (URL) -> Void = { old in
                     do { try FileManager.checked.trashItem(at: old) } catch { try? FileManager.checked.removeItem(at: old) }
                 }) throws -> URL {
        let target = URL(filePath: destination, directoryHint: .isDirectory)
        if case .openInstalled = self { return target }
        let folder = target.deletingLastPathComponent()
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let staged = folder.appending(path: ".cmux-move-\(UUID().uuidString)-\(target.lastPathComponent)", directoryHint: .isDirectory)
        do { try files.copyItem(at: running, to: staged) } catch {
            try? files.removeItem(at: staged)  // a half copy must not stay behind as another hidden .app
            throw error
        }
        Self.clearQuarantine(in: staged, files: files)
        var aside: URL?
        if case .replace = self {
            let old = folder.appending(path: ".cmux-replaced-\(UUID().uuidString)-\(target.lastPathComponent)", directoryHint: .isDirectory)
            do { try files.moveItem(at: target, to: old) } catch {
                try? files.removeItem(at: staged)
                throw error
            }
            aside = old
        }
        do { try files.moveItem(at: staged, to: target) } catch {
            if let aside { try? files.moveItem(at: aside, to: target) }
            try? files.removeItem(at: staged)
            throw error
        }
        if let aside { trash(aside) }
        return target
    }

    /// Removes `com.apple.quarantine` from `bundle` and everything in it.
    static func clearQuarantine(in bundle: URL, files: CheckedFileManager) {
        removexattr(bundle.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        for relative in (try? files.subpathsOfDirectory(atPath: bundle.path)) ?? [] {
            removexattr(bundle.appending(path: relative).path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    /// `/bin/sh` that waits for `pid` to exit, ejects `volume` (the disk image the app ran from, when there is one)
    /// and opens `app`: that exact bundle, never a lookup by bundle id.
    static func reopenCommand(pid: pid_t, app: String, ejecting volume: String?) -> [String] {
        ["/bin/sh", "-c", "/usr/bin/caffeinate -w \"$0\"; [ -n \"$2\" ] && /usr/bin/hdiutil detach -quiet \"$2\"; exec /usr/bin/open \"$1\"",
         String(pid), app, volume.flatMap { $0.hasPrefix("/Volumes/") ? $0 : nil } ?? ""]
    }
}
