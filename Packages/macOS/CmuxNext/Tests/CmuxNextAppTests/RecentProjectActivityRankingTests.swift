import CmuxNextOnboarding
import Foundation
import Synchronization
import Testing

/// The first-run folder picker ranks the folders the user is most active in first
/// (https://github.com/manaflow-ai/cmux/issues/46904): git activity, the shell's visits (zoxide, z,
/// `cd` history), and never a look inside a privacy-protected folder (LAUNCH-NO-TCC-PROMPTS).
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RecentProjectActivityRankingTests {
    let home: URL
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appending(path: "activity-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    /// A repository at `relative` under the home folder whose git files were last written `daysAgo`.
    @discardableResult
    func repository(_ relative: String, daysAgo: Double, folderDaysAgo: Double? = nil) throws -> URL {
        let folder = home.appending(path: relative, directoryHint: .isDirectory)
        let git = folder.appending(path: ".git", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: git.appending(path: "logs"), withIntermediateDirectories: true)
        let when = now.addingTimeInterval(-daysAgo * 86_400)
        for file in ["logs/HEAD", "index", "HEAD"] {
            let url = git.appending(path: file)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: url.path)
        }
        for url in [git.appending(path: "logs"), git, folder] {
            let date = url == folder ? now.addingTimeInterval(-(folderDaysAgo ?? daysAgo) * 86_400) : when
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        return folder.standardizedFileURL
    }

    func scan(activity: FolderActivity = FolderActivity(), fileSystem: ScanFileSystem = .live) -> RecentProjectScan {
        var projects = AgentProjectScan(home: home)
        projects.fileSystem = fileSystem
        return RecentProjectScan(projects: projects, activity: activity)
    }

    @Test func gitActivityOutranksTheFolderDate() throws {
        // `old` has the newer folder date but no recent commit; `busy` was committed to today.
        let busy = try repository("code/busy", daysAgo: 0, folderDaysAgo: 300)
        let old = try repository("code/old", daysAgo: 200, folderDaysAgo: 0)
        let ranked = scan().run(now: now).map(\.id)
        #expect(ranked == [busy.path, old.path])
    }

    @Test func linkedWorktreeUsesItsGitDir() throws {
        let main = try repository("code/main", daysAgo: 100)
        let gitDir = main.appending(path: ".git/worktrees/feature", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: gitDir.appending(path: "index"))
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: gitDir.appending(path: "index").path)
        let worktree = home.appending(path: "code/feature", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("gitdir: \(gitDir.path)\n".utf8).write(to: worktree.appending(path: ".git"))
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-300 * 86_400)], ofItemAtPath: worktree.appending(path: ".git").path)
        #expect(scan().gitActivity(worktree) == now)
        #expect(scan().run(now: now).first?.id == worktree.standardizedFileURL.path)
    }

    @Test func shellVisitsRankTheirRepositoryFirst() throws {
        // Equal git activity; the shell lives in `loved`, outside every scanned root.
        let quiet = try repository("code/quiet", daysAgo: 3)
        let loved = try repository("elsewhere/loved", daysAgo: 3)
        try "cd ~/elsewhere/loved/Sources\ncd \(loved.path)\n".write(to: home.appending(path: ".bash_history"), atomically: true, encoding: .utf8)
        let activity = FolderActivity.read(home: home, now: now)
        let ranked = scan(activity: activity).run(now: now).map(\.id)
        #expect(ranked == [loved.path, quiet.path])
    }

    @Test func zoxideDatabaseIsRead() throws {
        let folder = home.appending(path: "work/app").path
        var data = Data()
        func le<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        le(UInt32(3))
        le(UInt64(1))
        le(UInt64(folder.utf8.count))
        data.append(contentsOf: folder.utf8)
        le(Double(12.5).bitPattern)
        le(UInt64(now.timeIntervalSince1970))
        let dir = home.appending(path: ".local/share/zoxide", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appending(path: "db.zo"))
        let visits = FolderActivity.read(home: home, now: now).visits[folder]
        #expect(visits == FolderActivity.Visits(weight: 12.5, last: now))
    }

    @Test func zAndZshAndFishHistoriesAreRead() throws {
        try "\(home.path)/z-dir|7|1700000000\n".write(to: home.appending(path: ".z"), atomically: true, encoding: .utf8)
        try ": 1700000100:0;cd ~/zsh-dir && ls\n: 1700000200:0;git status\n".write(
            to: home.appending(path: ".zsh_history"), atomically: true, encoding: .utf8)
        let fish = home.appending(path: ".local/share/fish", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fish, withIntermediateDirectories: true)
        try "- cmd: cd ~/fish-dir\n  when: 1700000300\n- cmd: cd relative\n  when: 1700000400\n".write(
            to: fish.appending(path: "fish_history"), atomically: true, encoding: .utf8)
        let visits = FolderActivity.read(home: home, now: now).visits
        #expect(visits["\(home.path)/z-dir"] == FolderActivity.Visits(weight: 7, last: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(visits["\(home.path)/zsh-dir"] == FolderActivity.Visits(weight: 1, last: Date(timeIntervalSince1970: 1_700_000_100)))
        #expect(visits["\(home.path)/fish-dir"] == FolderActivity.Visits(weight: 1, last: Date(timeIntervalSince1970: 1_700_000_300)))
        #expect(visits.count == 3)
    }

    @Test func cdTargets() {
        #expect(FolderActivity.cdTarget("cd /a/b") == "/a/b")
        #expect(FolderActivity.cdTarget("  pushd ~/x; make") == "~/x")
        #expect(FolderActivity.cdTarget("cd ~/My\\ Repo && ls") == "~/My Repo")
        #expect(FolderActivity.cdTarget("cd relative") == nil)
        #expect(FolderActivity.cdTarget("cd -") == nil)
        #expect(FolderActivity.cdTarget("cdx /a") == nil)
        #expect(FolderActivity.cdTarget("echo cd /a") == nil)
    }

    @Test func protectedFoldersAreNeverProbed() throws {
        // The shell visited a repository in Documents and one on the Desktop: neither is offered,
        // and no probe of the scan touches either (or Downloads, or iCloud Drive).
        let fine = try repository("code/fine", daysAgo: 1)
        let protected = ["Documents/secret", "Desktop/thing", "Downloads/x", "Library/Mobile Documents/com~apple~CloudDocs/y"]
        var activity = FolderActivity()
        for path in protected { activity.add("~/\(path)", home: home, weight: 50, last: now) }
        activity.add(fine.path, home: home, weight: 1, last: now)
        let touched = Mutex<[String]>([])
        let live = ScanFileSystem.live
        func record(_ path: String) { touched.withLock { $0.append(path) } }
        var recording = ScanFileSystem(
            isDirectory: { record($0); return live.isDirectory($0) },
            exists: { record($0); return live.exists($0) },
            subdirectories: { record($0.path); return live.subdirectories($0) },
            modified: { record($0); return live.modified($0) },
            resolve: { live.resolve($0) })
        recording.readPrefix = { record($0); return live.readPrefix($0, $1) }
        let ranked = scan(activity: activity, fileSystem: recording).run(hints: ["~/Documents/hinted"], now: now).map(\.id)
        #expect(ranked.first == fine.path)
        #expect(!ranked.contains { $0.contains("/Desktop/") || $0.contains("/Downloads/") || $0.contains("Mobile Documents") })
        let lowered = ["Documents", "Desktop", "Downloads", "Library/Mobile Documents"].map { "\(home.path)/\($0)".lowercased() }
        let leaks = touched.withLock { $0 }.filter { path in
            lowered.contains { path.lowercased() == $0 || path.lowercased().hasPrefix($0 + "/") }
        }
        #expect(leaks.isEmpty, "probed inside a protected folder: \(leaks)")
    }
}
