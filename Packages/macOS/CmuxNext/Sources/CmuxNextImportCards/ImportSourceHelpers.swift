import CmuxNextCompat
import CmuxNextImportSuggestions
import CmuxNextOnboarding
import Foundation

/// cmux Classic's saved workspaces that have not come over yet: classic's
/// session file against the migration ledger, as an automatic run would plan
/// it. A session file over ``maximumSessionBytes`` is not read (the card is
/// a hint; Import Workspaces from Classic cmux still reads it). The file read and the plan run
/// on the files lane at `.bestEffort` (nobody waits for the card).
nonisolated struct ClassicWorkspaceCount: Sendable {
    static let maximumSessionBytes = 32 * 1024 * 1024

    var support: URL
    var bundleID: String?

    init(support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
         bundleID: String? = Bundle.main.bundleIdentifier) {
        self.support = support
        self.bundleID = bundleID
    }

    /// Where the migration keeps its ledger (`AppOnboardingServices.classicMigrationDirectory`).
    var ledgerDirectory: URL {
        support.appending(path: "cmux-next", directoryHint: .isDirectory)
            .appending(path: bundleID ?? "com.cmuxterm.app.next", directoryHint: .isDirectory)
            .appending(path: "classic-migration", directoryHint: .isDirectory)
    }

    /// The count; nil when classic left no session file that can be read, or a read was dropped (quit).
    func count(on lanes: any MayBlockRunner) async -> Int? {
        let read = try? await lanes.runFiles(.bestEffort) { readSession() }
        guard let snapshot = read ?? nil else { return nil }
        let ledger: ClassicMigrationLedger?
        switch await ClassicMigrationRepository(directory: ledgerDirectory).load() {
        case .ledger(let saved): ledger = saved
        default: ledger = nil
        }
        return try? await lanes.runFiles(.bestEffort) {
            ClassicMigrationPlanner().plan(snapshot, ledger: ledger, live: [], liveGroups: [], mode: .automatic).workspaces.count
        }
    }

    /// Classic's session file, when there is one of at most ``maximumSessionBytes`` that reads.
    private func readSession() -> ClassicSessionSnapshot? {
        let finder = ClassicMigrationSourceFinder(support: support, ownBundleID: bundleID)
        guard let candidate = finder.candidates().first else { return nil }
        let size = ((try? FileManager.default.attributesOfItem(atPath: candidate.url.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= Self.maximumSessionBytes else { return nil }
        return try? ClassicSessionImporter(fileURL: candidate.url).readSnapshot()
    }
}

/// An iTerm2 profile's colors as a Ghostty theme in the person's themes folder
/// (`~/.config/ghostty/themes`, where Ghostty and every cmux theme picker look),
/// named `iTerm2 <profile>`. Colors only, as every cmux theme file. Off the main thread.
nonisolated struct ITermThemeWriter: Sendable {
    var home: URL
    var variables: [String: String]

    var folder: URL {
        let config = variables["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appending(path: ".config", directoryHint: .isDirectory)
        return config.appending(path: "ghostty/themes", directoryHint: .isDirectory)
    }

    /// The theme name for `profile`: letters, digits, spaces, dashes and dots only.
    static func name(_ profile: String) -> String {
        let kept = profile.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || " -_.".unicodeScalars.contains($0) }
        let clean = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return "iTerm2 \(clean.isEmpty ? "Default" : String(clean.prefix(64)))"
    }

    /// Writes the preferred profile's theme; returns its name, nil when iTerm2 has no colors to bring.
    func write() throws -> String? {
        let file = home.appending(path: "Library/Preferences/com.googlecode.iterm2.plist")
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= ImportScanner.maximumPreferencesBytes, let data = try? Data(contentsOf: file),
              let profile = ITermProfiles(data: data)?.preferred, !profile.themeLines.isEmpty else { return nil }
        let name = Self.name(profile.name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = ["# \(name): colors of the iTerm2 profile, imported by cmux"] + profile.themeLines
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: folder.appending(path: name), options: .atomic)
        return name
    }
}
