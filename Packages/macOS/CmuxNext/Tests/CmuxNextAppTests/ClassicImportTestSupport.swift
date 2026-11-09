@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation

/// A scratch home folder as the daemon's `classic_import.*` operations see it (the test daemon
/// runs with `HOME` set to it): classic's saved sessions, classic's state folder, and the
/// migration's folder with its ledger.
struct ClassicTestHome {
    let root: URL

    /// `~/Library/Application Support`.
    var support: URL { root.appendingPathComponent("Library/Application Support", isDirectory: true) }
    /// Classic's own folder, holding `session-<bundle>.json`, its `-previous` copy and `session-history/`.
    var classic: URL { support.appendingPathComponent("cmux", isDirectory: true) }
    /// Classic's state folder (`~/.local/state/cmux`), holding its launch sentinel.
    var state: URL { root.appendingPathComponent(".local/state/cmux", isDirectory: true) }

    func session(_ bundle: String = "com.cmuxterm.app", suffix: String = "") -> URL {
        classic.appendingPathComponent("session-\(bundle)\(suffix).json")
    }

    /// The migration's folder for the app with `bundleID` (``AppOnboardingServices/classicBundleID``).
    func migration(_ bundleID: String) -> URL {
        support.appendingPathComponent("cmux-next/\(bundleID)/classic-migration", isDirectory: true)
    }

    /// Classic of `bundle` launches (writes its sentinel) or quits cleanly (removes it).
    func classicRunning(_ running: Bool, bundle: String = "com.cmuxterm.app") throws {
        let sentinel = state.appendingPathComponent("lifecycle/\(bundle)/running.sentinel")
        if running {
            try FileManager.default.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("pid=4242\n".utf8).write(to: sentinel)
        } else {
            try? FileManager.default.removeItem(at: sentinel)
        }
    }

    /// The test daemon's environment: this home, and classic's state folder inside it.
    func daemonEnvironment(shell: String = "/bin/sh") -> [String: String] {
        ["HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent(".local/state").path,
         "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": shell, "TERM": "xterm-256color"]
    }

    /// `tests/fixtures/classic-to-next/<name>` in this repository.
    static func fixture(_ name: String) -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("tests/fixtures/classic-to-next/\(name)")
    }
}

/// The migration ledger as the daemon writes it (`cmux_classic_import::ledger::Ledger`), for
/// tests that read it or set up a cut-off run.
struct ClassicTestLedger: Codable, Equatable {
    struct Entry: Codable, Equatable {
        /// `pending`, `created`, `done` or `skipped`.
        var stage: String
        var nextWorkspace: String?
        var reason: String?
    }

    struct Source: Codable, Equatable {
        var path: String
        var bundleID: String
        var size: Int
        var modifiedAt: Double
        var createdAt: Double?
    }

    var schema = 1
    /// `inProgress` or `completed`.
    var state: String
    var source: Source?
    var workspaces: [String: Entry] = [:]
    var groups: [String: String] = [:]
    var runs = 0
    var appVersion: String?
    var updatedAt: Double = 0
    var declinedAt: Double?

    static func read(_ folder: URL) throws -> ClassicTestLedger {
        try JSONDecoder().decode(ClassicTestLedger.self, from: Data(contentsOf: folder.appendingPathComponent("ledger.json")))
    }

    func write(_ folder: URL) throws {
        try JSONEncoder().encode(self).write(to: folder.appendingPathComponent("ledger.json"), options: .atomic)
    }
}

/// The daemon's decisions, by name.
extension ClassicImportReply.Decision {
    static let firstRun = Self(decision: "first_run")
    static let resume = Self(decision: "resume")
    static let merge = Self(decision: "merge")
    static func skip(_ reason: String) -> Self { Self(decision: "skip", reason: reason) }
}

/// The fixture `session-groups.json`: classic 0.64.19's split-workspace session, extended by
/// hand in classic's schema with a second window, two groups (one collapsed with color and icon,
/// one pinned and empty), a colored grouped workspace, a pinned one, a Cloud VM workspace, and a
/// `stableId` saved twice.
extension ClassicTestHome {
    static let groupsFixture = fixture("session-groups.json")
    /// The fixture's collapsed Backend group's id.
    static let backendGroup = "11111111-1111-4111-8111-111111111111"
    /// The fixture's pinned workspace's key.
    static let pinnedKey = "AAAAAAAA-0000-4000-8000-000000000003"
}
