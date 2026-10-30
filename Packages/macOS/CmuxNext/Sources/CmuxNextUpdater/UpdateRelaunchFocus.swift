import AppKit
public import Foundation

/// An update never pulls the user into the app. Sparkle relaunches into an installed update through
/// LaunchServices, which brings the new process to the front; for an install nobody clicked, in an
/// app the user was not in, that took the user out of the app they were working in (a NIGHTLY user
/// was put in NEXT DEV on every tip build).
///
/// Just before Sparkle relaunches, the updater records here whether the relaunched app may come to
/// the front. The relaunched process reads the record once at launch (``consume(defaults:build:now:)``)
/// and, when it says "stay behind", refuses activation through its startup and hands the front back
/// to the app that had it. A click (Restart to Update, the update card) or an app that was frontmost
/// writes no record, so those relaunches activate as before.
public nonisolated struct UpdateRelaunchFocus: Codable, Equatable, Sendable {
    /// The build Sparkle installs (`CFBundleVersion`); nil when Sparkle did not name it. A relaunch
    /// into another build (the install failed, a later manual launch) ignores the record.
    public var targetBuild: String?
    public var recordedAt: Date
    /// The app that was frontmost when the relaunch began: the front goes back to it.
    public var frontmostPID: Int32?
    public var frontmostBundleID: String?

    public init(targetBuild: String?, recordedAt: Date, frontmostPID: Int32?, frontmostBundleID: String?) {
        self.targetBuild = targetBuild
        self.recordedAt = recordedAt
        self.frontmostPID = frontmostPID
        self.frontmostBundleID = frontmostBundleID
    }

    /// The defaults key of the record (the app's own domain, so each build channel keeps its own).
    public static let key = "cmux.next.updates.relaunchFocus"
    /// A record older than this is stale: the relaunch it was written for never came. Sparkle
    /// relaunches as soon as the installer has swapped the bundle (seconds); a short limit keeps a
    /// record whose relaunch failed from holding a later launch the user started behind.
    public static let maxAge: TimeInterval = 90

    /// Whether the relaunch about to happen must stay behind: an install nobody clicked, in an app
    /// that is not the frontmost one. A click, or the user being in the app, keeps the activation.
    public static func staysBehind(automatic: Bool, appIsFrontmost: Bool) -> Bool {
        automatic && !appIsFrontmost
    }

    /// Whether this launch is the relaunch `record` was written for: the same build (when it was
    /// named) and recent. Anything else is a stale record and does nothing.
    public func applies(toBuild build: String, now: Date) -> Bool {
        if let targetBuild, targetBuild != build { return false }
        let age = now.timeIntervalSince(recordedAt)
        return age >= -60 && age <= Self.maxAge
    }

    /// Writes `record` (a relaunch that stays behind), or removes any record (nil: a relaunch that
    /// activates as before).
    public static func write(_ record: UpdateRelaunchFocus?, defaults: UserDefaults) {
        guard let record, let data = try? JSONEncoder().encode(record) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    /// The launch argument of an automatic install's background reopen (``UpdateRelaunchBehind``):
    /// that launch stays behind whatever build it starts (the installed one, or the previous one
    /// Sparkle put back after a failed install) and however long the quit took.
    public static let reopenArgument = "--cmux-update-reopened-behind"

    /// Reads and clears the record at launch: the record when this launch is the relaunch it was
    /// written for, else nil (no record, unreadable, or stale). A background reopen
    /// (`reopenedBehind`) always stays behind: its record when there is one, else one with no app
    /// to hand the front back to.
    public static func consume(defaults: UserDefaults = .standard, build: String, now: Date = Date(),
                               reopenedBehind: Bool = false) -> UpdateRelaunchFocus? {
        let data = defaults.data(forKey: key)
        if data != nil { defaults.removeObject(forKey: key) }
        let record = data.flatMap { try? JSONDecoder().decode(UpdateRelaunchFocus.self, from: $0) }
        if reopenedBehind {
            return record ?? UpdateRelaunchFocus(targetBuild: nil, recordedAt: now, frontmostPID: nil, frontmostBundleID: nil)
        }
        guard let record, record.applies(toBuild: build, now: now) else { return nil }
        return record
    }
}

/// Whether this app is frontmost when a relaunch begins, and which app is.
public nonisolated struct UpdateFrontmostApp: Equatable, Sendable {
    public var isThisApp: Bool
    public var pid: Int32?
    public var bundleID: String?

    public init(isThisApp: Bool, pid: Int32?, bundleID: String?) {
        self.isThisApp = isThisApp
        self.pid = pid
        self.bundleID = bundleID
    }

    /// AppKit's answer. Read once, just before the app quits for the relaunch.
    @MainActor public static func current() -> UpdateFrontmostApp {
        let front = NSWorkspace.shared.frontmostApplication
        let me = ProcessInfo.processInfo.processIdentifier
        return UpdateFrontmostApp(isThisApp: NSApp.isActive || front?.processIdentifier == me,
                                  pid: front?.processIdentifier, bundleID: front?.bundleIdentifier)
    }
}
