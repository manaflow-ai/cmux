import CmuxNextBrowserImport
import Foundation
import Testing
@testable import CmuxNextOnboarding

/// LAUNCH-NO-TCC-PROMPTS: the scans that run at launch, in onboarding and on
/// the new tab page never probe a path in a privacy-protected location
/// (Desktop, Documents, Downloads, Pictures, Music, Movies, iCloud Drive,
/// cloud storage, other apps' data, other and network volumes), by its
/// spelling or through a symlink, and never list the home folder. A recording
/// file system stands in for the disk; the agents' own transcripts are real
/// files in a fixture home.
@Suite struct LaunchNoPrivacyPromptTests {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "launch-tcc-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func path(_ relative: String) -> String { home.appending(path: relative).standardizedFileURL.path }

    /// Every protected location of the fixture home, as macOS guards them.
    var protectedRoots: [String] {
        ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies", "Library/Mobile Documents",
         "Library/CloudStorage", "Library/Containers", "Library/Group Containers", "Library/Mail",
         "Library/Messages", "Library/Safari", "Library/Calendars"].map(path) + ["/Volumes", "/Network"]
    }

    /// The disk as the scan sees it: every path is a folder, `links` maps a
    /// symlink to its target, `children` lists folders. Records every probe.
    nonisolated final class Recorder: Sendable {
        let probes = Locked<[String]>([])
        let listings = Locked<[String]>([])
        let links: [String: String]
        let children: [String: [String]]

        init(links: [String: String] = [:], children: [String: [String]] = [:]) {
            self.links = links
            self.children = children
        }

        func resolve(_ path: String) -> String {
            for (link, target) in links where path == link || path.hasPrefix(link + "/") {
                return target + path.dropFirst(link.count)
            }
            return path
        }

        var fileSystem: ScanFileSystem {
            ScanFileSystem(
                isDirectory: { [self] in probe($0); return true },
                exists: { [self] in probe($0); return false },
                subdirectories: { [self] url in
                    probe(url.path)
                    listings.withLock { $0.append(url.path) }
                    return children[url.path] ?? []
                },
                modified: { [self] in probe($0); return .distantPast },
                resolve: { [self] in resolve($0) })
        }

        private func probe(_ path: String) { probes.withLock { $0.append(path) } }
    }

    /// A value behind a lock, for the recorder's `@Sendable` closures.
    nonisolated final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
    }

    /// The probes that would raise a prompt: inside a protected root, also after resolving links.
    func promptingProbes(_ recorder: Recorder) -> [String] {
        func inside(_ path: String) -> Bool {
            let lower = path.lowercased()
            return protectedRoots.contains { root in
                let root = root.lowercased()
                return lower == root || lower.hasPrefix(root + "/")
            }
        }
        return recorder.probes.withLock { $0 }.filter { inside($0) || inside(recorder.resolve($0)) }
    }

    func writeTranscripts(_ cwds: [String]) throws {
        for (index, cwd) in cwds.enumerated() {
            let file = home.appending(path: ".claude/projects/p\(index)/\(UUID().uuidString).jsonl")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let record: [String: Any] = ["type": "user", "cwd": cwd, "message": ["role": "user", "content": "prompt \(index)"]]
            try (String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self) + "\n")
                .write(to: file, atomically: true, encoding: .utf8)
        }
    }

    var guardedCwds: [String] {
        ["Desktop/a", "Documents/b", "Downloads/c", "Pictures/d", "Music/e", "Movies/f",
         "Library/Mobile Documents/com~apple~CloudDocs/g", "Library/Containers/com.apple.Notes/Data/h",
         "Library/Group Containers/group.x/i", "Library/Mail/j", "Library/Safari/k", "Library/Calendars/l",
         "linked/m"].map(path) + ["/Volumes/External/n", "/Network/Servers/o"]
    }

    @Test func theLaunchProjectScanNeverProbesAProtectedFolder() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try writeTranscripts(guardedCwds + [path("code/app")])
        let recorder = Recorder(
            links: [path("linked"): path("Documents"), path("Projects/docs"): path("Downloads")],
            children: [path("Projects"): ["docs", "deep"], path("Projects/deep"): ["a"], path("Projects/deep/a"): ["b"],
                       path("Projects/deep/a/b"): ["c"], path("Projects/deep/a/b/c"): ["d"]])
        var scan = AgentProjectScan(home: home)
        scan.fileSystem = recorder.fileSystem
        let projects = scan.run()

        #expect(promptingProbes(recorder) == [])
        #expect(!recorder.listings.withLock { $0 }.contains(home.standardizedFileURL.path))
        // A Projects root is walked at most three folders down.
        #expect(recorder.listings.withLock { $0 }.contains(path("Projects/deep/a")))
        #expect(!recorder.listings.withLock { $0 }.contains(path("Projects/deep/a/b")))
        // Guarded folders stay in the list by name, unlooked-at, for the person to pick.
        let ids = Set(projects.map(\.id))
        #expect(ids.isSuperset(of: Set(guardedCwds)))
        #expect(ids.contains(path("code/app")))
    }

    @Test func theNewTabProjectListNeverProbesAProtectedFolder() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try writeTranscripts([path("code/app")])
        // `~/code` leads into Downloads through a symlink; `~/src` is a plain root.
        let recorder = Recorder(links: [path("code"): path("Downloads/code")],
                                children: [path("src"): ["tool"]])
        var projects = AgentProjectScan(home: home)
        projects.fileSystem = recorder.fileSystem
        let scan = RecentProjectScan(projects: projects)
        _ = scan.run(hints: guardedCwds + [path("work/hinted")])
        _ = scan.complete(query: "Doc", hints: guardedCwds)

        #expect(promptingProbes(recorder) == [])
        #expect(!recorder.listings.withLock { $0 }.contains(home.standardizedFileURL.path))
    }

    @Test func theChatScanNeverProbesAProtectedFolder() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try writeTranscripts(guardedCwds)
        let recorder = Recorder(links: [path("linked"): path("Documents")])
        var projects = AgentProjectScan(home: home)
        projects.fileSystem = recorder.fileSystem
        let chats = AgentChatScan(projects: projects).run()

        #expect(promptingProbes(recorder) == [])
        #expect(chats.count == guardedCwds.count)
    }

    /// The Import step shows without reading other apps' data; Find Browsers (a person) reads it.
    @MainActor @Test func theImportStepReadsBrowserDataOnlyWhenAPersonAsks() async {
        let services = MockOnboardingServices()
        let model = OnboardingModel(services: services, start: .importData)
        model.stepDidAppear()
        for _ in 0..<50 { await Task.yield() }
        #expect(services.detections == 0)
        #expect(model.importer.phase == .idle)
        #expect(model.primaryTitle == OnboardingStrings.findBrowsers)
        model.next()
        await settle { model.importer.phase == .ready }
        #expect(services.detections == 1)
        #expect(model.step == .importData, "Find Browsers stays on the step to show what it found")
    }

    @MainActor func settle(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { await Task.yield() }
    }
}
