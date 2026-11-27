import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The pickers fold a repository's worktrees under one row (`project.list` `repos`): the host reads
/// each folder's repository from Git's own small files, never by running `git`, and never reads a
/// Git folder inside a macOS privacy-protected folder (LAUNCH-NO-TCC-PROMPTS). A project in a
/// GitHub project draws its owner's avatar, else its icon file, else its manifest's framework or
/// language mark (`project.icon`).
@Suite(.serialized)
struct AgentPaneProjectRepoTests {
    nonisolated private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D])
    private static let githubConfig = """
        [core]
        \tbare = false
        [remote "upstream"]
        \turl = git@github.com:someone/fork.git
        [remote "origin"]
        \turl = git@github.com:manaflow-ai/cmux.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """

    /// Every path a reader reads or stats, and every fetch.
    private nonisolated final class Touches: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ path: String) { lock.withLock { paths.append(path) } }
        var all: [String] { lock.withLock { paths } }
    }

    /// A date a test moves forward by hand.
    private nonisolated final class SteppedDate: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date()
        var date: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
    }

    private struct Fixture {
        let home: String
        let touches = Touches()

        init() throws {
            let made = FileManager.default.temporaryDirectory.appendingPathComponent("project-repo-\(UUID().uuidString)/home").path
            try FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true)
            guard let resolved = realpath(made, nil) else { throw CocoaError(.fileNoSuchFile) }
            defer { free(resolved) }
            home = String(cString: resolved)
        }

        func write(_ text: String, _ relative: String) throws {
            try write(Data(text.utf8), relative)
        }

        func write(_ data: Data, _ relative: String) throws {
            let path = home + "/" + relative
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path))
        }

        func folder(_ relative: String) throws {
            try FileManager.default.createDirectory(atPath: home + "/" + relative, withIntermediateDirectories: true)
        }

        var repos: AgentPaneProjectRepoReader {
            let live = AgentPaneProjectRepoReader(home: home)
            let touches = touches
            var reader = live
            reader.read = { touches.add($0); return live.read($0) }
            return reader
        }

        var icons: AgentPaneProjectIcon {
            let live = AgentPaneProjectIcon(home: home)
            let touches = touches
            var reader = live
            reader.stat = { touches.add($0); return live.stat($0) }
            reader.read = { touches.add($0); return live.read($0) }
            reader.readManifest = { touches.add($0); return live.readManifest($0) }
            reader.list = { touches.add($0); return live.list($0) }
            return reader
        }

        func remove() { try? FileManager.default.removeItem(atPath: (home as NSString).deletingLastPathComponent) }
    }

    /// A main checkout with a worktree of its own, as `git worktree add` lays them out.
    private func checkout(_ fixture: Fixture) throws {
        try fixture.write("ref: refs/heads/main\n", "code/cmux/.git/HEAD")
        try fixture.write(Self.githubConfig, "code/cmux/.git/config")
        try fixture.write("ref: refs/heads/feat/picker\n", "code/cmux/.git/worktrees/picker/HEAD")
        try fixture.write("../..\n", "code/cmux/.git/worktrees/picker/commondir")
        try fixture.write("gitdir: ../../../code/cmux/.git/worktrees/picker\n", "wt/cmux/picker/.git")
    }

    @Test func aMainCheckoutIsItsOwnRepositoryNamedForItsGitHubRepository() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try checkout(fixture)
        #expect(fixture.repos.repo(for: fixture.home + "/code/cmux")
            == AgentPaneProjectRepo(
                root: fixture.home + "/code/cmux", top: fixture.home + "/code/cmux", name: "cmux", branch: "main", github: "manaflow-ai/cmux"))
    }

    @Test func aLinkedWorktreeBelongsToItsMainCheckout() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try checkout(fixture)
        #expect(fixture.repos.repo(for: fixture.home + "/wt/cmux/picker")
            == AgentPaneProjectRepo(
                root: fixture.home + "/code/cmux", top: fixture.home + "/wt/cmux/picker", name: "cmux", branch: "feat/picker", github: "manaflow-ai/cmux"))
    }

    @Test func aFolderInsideARepositoryFindsItAbove() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try checkout(fixture)
        try fixture.folder("code/cmux/webviews/src")
        let repo = fixture.repos.repo(for: fixture.home + "/code/cmux/webviews/src")
        #expect(repo?.root == fixture.home + "/code/cmux")
        #expect(repo?.top == fixture.home + "/code/cmux")
    }

    @Test func aDetachedHeadHasNoBranchAndNoRemoteNamesItForItsFolder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("0123456789abcdef0123456789abcdef01234567\n", "code/tool/.git/HEAD")
        #expect(fixture.repos.repo(for: fixture.home + "/code/tool")
            == AgentPaneProjectRepo(
                root: fixture.home + "/code/tool", top: fixture.home + "/code/tool", name: "tool", branch: nil, github: nil))
    }

    @Test func aBareRepositoryIsTheRootOfItsWorktrees() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("ref: refs/heads/main\n", "code/lib.git/HEAD")
        try fixture.write("ref: refs/heads/next\n", "code/lib.git/worktrees/next/HEAD")
        try fixture.write("../..\n", "code/lib.git/worktrees/next/commondir")
        try fixture.write("gitdir: \(fixture.home)/code/lib.git/worktrees/next\n", "code/lib-next/.git")
        #expect(fixture.repos.repo(for: fixture.home + "/code/lib-next")
            == AgentPaneProjectRepo(
                root: fixture.home + "/code/lib.git", top: fixture.home + "/code/lib-next", name: "lib", branch: "next", github: nil))

        // A bare repository in a hidden folder of the checkout is named for the checkout.
        try fixture.write("ref: refs/heads/main\n", "code/app/.bare/HEAD")
        try fixture.write("ref: refs/heads/main\n", "code/app/.bare/worktrees/main/HEAD")
        try fixture.write("../..\n", "code/app/.bare/worktrees/main/commondir")
        try fixture.write("gitdir: ../.bare/worktrees/main\n", "code/app/main/.git")
        #expect(fixture.repos.repo(for: fixture.home + "/code/app/main")?.root == fixture.home + "/code/app")
        #expect(fixture.repos.repo(for: fixture.home + "/code/app/main")?.name == "app")
    }

    @Test func aHiddenMainCheckoutIsItsOwnRootNotItsParent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("ref: refs/heads/main\n", "code/.github/.git/HEAD")
        try fixture.write("ref: refs/heads/main\n", "code/.dotfiles/.git/HEAD")
        let github = fixture.repos.repo(for: fixture.home + "/code/.github")
        #expect(github?.root == fixture.home + "/code/.github")
        #expect(github?.name == ".github")
        #expect(fixture.repos.repo(for: fixture.home + "/code/.dotfiles")?.root == fixture.home + "/code/.dotfiles")
    }

    @Test func aSubmoduleIsItsOwnRepositoryRootedAtItsCheckout() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try checkout(fixture)
        try fixture.write("ref: refs/heads/trunk\n", "code/cmux/.git/modules/ghostty/HEAD")
        try fixture.write("gitdir: ../.git/modules/ghostty\n", "code/cmux/ghostty/.git")
        let repo = fixture.repos.repo(for: fixture.home + "/code/cmux/ghostty")
        #expect(repo?.root == fixture.home + "/code/cmux/ghostty")
        #expect(repo?.top == fixture.home + "/code/cmux/ghostty")
        #expect(repo?.name == "ghostty")
        #expect(repo?.branch == "trunk")
    }

    @Test func aFolderInNoRepositoryIsLeftOut() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try checkout(fixture)
        try fixture.folder("code/plain")
        let repos = fixture.repos.repos(for: [fixture.home + "/code/plain", fixture.home + "/wt/cmux/picker"])
        #expect(repos.keys.sorted() == [fixture.home + "/wt/cmux/picker"])
        #expect(!fixture.touches.all.contains(fixture.home + "/.git"), "the walk stops below the home folder")
    }

    @Test func originIsReadFromItsOwnSection() {
        #expect(AgentPaneProjectRepoReader.origin(Self.githubConfig) == "git@github.com:manaflow-ai/cmux.git")
        #expect(AgentPaneProjectRepoReader.origin("[remote \"upstream\"]\n\turl = x\n") == nil)
        #expect(AgentPaneProjectRepoReader.branch("ref: refs/heads/a/b\n") == "a/b")
        #expect(AgentPaneProjectRepoReader.branch("ref: refs/remotes/origin/a\n") == nil)
    }

    @Test func aWorktreeWhoseGitFolderIsInAProtectedFolderIsNeverRead() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("ref: refs/heads/main\n", "Documents/repo/.git/HEAD")
        try fixture.write("ref: refs/heads/x\n", "Documents/repo/.git/worktrees/x/HEAD")
        try fixture.write("../..\n", "Documents/repo/.git/worktrees/x/commondir")
        try fixture.write("gitdir: \(fixture.home)/Documents/repo/.git/worktrees/x\n", "code/leak/.git")
        let reader = fixture.repos
        #expect(reader.repo(for: fixture.home + "/code/leak") == nil)
        #expect(reader.repo(for: fixture.home + "/Documents/repo") == nil)
        #expect(!fixture.touches.all.contains { $0.hasPrefix(fixture.home + "/Documents") }, "touched \(fixture.touches.all)")
    }

    @Test func theManifestNamesTheGlyph() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("// swift-tools-version: 6.2\n", "code/swift/Package.swift")
        try fixture.write("[package]\n", "code/rust/Cargo.toml")
        try fixture.write(#"{"dependencies":{"react":"19"}}"#, "code/react/package.json")
        try fixture.write(#"{"name":"x"}"#, "code/ts/package.json")
        try fixture.write("{}", "code/ts/tsconfig.json")
        try fixture.write(#"{"name":"x"}"#, "code/node/package.json")
        try fixture.write("[project]\n", "code/py/pyproject.toml")
        try fixture.write("module x\n", "code/go/go.mod")
        try fixture.write("source 'https://rubygems.org'\n", "code/rb/Gemfile")
        try fixture.folder("code/none")
        let reader = fixture.icons
        for (folder, glyph) in [("swift", "swift"), ("rust", "rust"), ("react", "react"), ("ts", "typescript"),
                                ("node", "node"), ("py", "python"), ("go", "go"), ("rb", "ruby")] {
            #expect(reader.glyph(in: fixture.home + "/code/" + folder) == glyph, "\(folder)")
        }
        #expect(reader.glyph(in: fixture.home + "/code/none") == nil)
        #expect(reader.glyph(in: fixture.home + "/Documents/x") == nil)
    }

    /// A package.json names the kind of app by its dependencies, the most specific framework first,
    /// and an app with no package manifest by its other files.
    @Test func theDependenciesNameTheFramework() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(#"{"dependencies":{"next":"15","react":"19"}}"#, "code/next/package.json")
        try fixture.write(#"{"dependencies":{"react":"19"},"devDependencies":{"vite":"7"}}"#, "code/react-vite/package.json")
        try fixture.write(#"{"devDependencies":{"vite":"7","typescript":"5"}}"#, "code/vite/package.json")
        try fixture.write(#"{"dependencies":{"vue":"3"},"devDependencies":{"vite":"7"}}"#, "code/vue/package.json")
        try fixture.write(#"{"devDependencies":{"@sveltejs/kit":"2"}}"#, "code/svelte/package.json")
        try fixture.write(#"{"dependencies":{"expo":"54","react-native":"0.81","react":"19"}}"#, "code/expo/package.json")
        try fixture.write(#"{"dependencies":{"react-native":"0.81","react":"19"}}"#, "code/react-native/package.json")
        try fixture.write(#"{"name":"x","description":"\"react\" in prose is no dependency"}"#, "code/prose/package.json")
        try fixture.write(#"{"name":"x"}"#, "code/tauri/package.json")
        try fixture.write("[package]\n", "code/tauri/src-tauri/Cargo.toml")
        try fixture.write(#"{"name":"x"}"#, "code/bun/package.json")
        try fixture.write("", "code/bun/bun.lock")
        try fixture.write("not json", "code/broken/package.json")
        try fixture.write(#"{"dependencies":{"react":"19","electron":"38"}}"#, "code/desktop/package.json")
        let padding = String(repeating: "x", count: AgentPaneProjectIcon.maximumBytes * 2)
        try fixture.write(#"{"description":""# + padding + #"","dependencies":{"react":"19"}}"#, "code/large/package.json")
        try fixture.folder("code/mac/Mac.xcodeproj")
        try fixture.write("dependencies:\n  flutter:\n    sdk: flutter\n", "code/flutter/pubspec.yaml")
        try fixture.write("const std = @import(\"std\");\n", "code/zig/build.zig")
        let reader = fixture.icons
        for (folder, glyph) in [("next", "next"), ("react-vite", "react"), ("vite", "vite"), ("vue", "vue"),
                                ("svelte", "svelte"), ("expo", "expo"), ("react-native", "react"), ("prose", "node"), ("tauri", "tauri"),
                                ("bun", "bun"), ("broken", "node"), ("mac", "swift"), ("flutter", "flutter"),
                                ("zig", "zig"), ("desktop", "electron"), ("large", "react")] {
            #expect(reader.glyph(in: fixture.home + "/code/" + folder) == glyph, "\(folder)")
        }
    }

    /// A GitHub project with a known framework answers the owner's avatar, which the badge draws,
    /// and still names its framework, which the badge draws when the avatar cannot be drawn.
    @Test func theOwnersAvatarComesWithTheFrameworkMark() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try checkout(fixture)
        try fixture.write("// swift-tools-version: 6.2\n", "code/cmux/Package.swift")
        let fetched = Touches()
        let avatars = AgentPaneOwnerAvatars(folder: nil, fetch: { url in fetched.add(url.absoluteString); return Self.png })
        let icons = AgentPaneProjectIcons(reader: fixture.icons, repos: fixture.repos, avatars: avatars)
        let answer = await icons.answer(for: fixture.home + "/wt/cmux/picker")
        #expect(answer.src == "data:image/png;base64," + Self.png.base64EncodedString())
        #expect(answer.glyph == "swift")
        #expect(fetched.all.count == 1)
    }

    @Test func aWorktreeWithNoIconUsesItsMainCheckoutsAndItsGlyph() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try checkout(fixture)
        try fixture.write(Self.png, "code/cmux/.cmux/icon.png")
        try fixture.write("// swift-tools-version: 6.2\n", "code/cmux/Package.swift")
        let icons = AgentPaneProjectIcons(reader: fixture.icons, repos: fixture.repos,
                                          avatars: AgentPaneOwnerAvatars(folder: nil, fetch: { _ in nil }))
        let answer = await icons.answer(for: fixture.home + "/wt/cmux/picker")
        #expect(answer.src == "data:image/png;base64," + Self.png.base64EncodedString())
        #expect(answer.glyph == "swift")
    }

    @Test func aGitHubProjectWithNoIconDrawsItsOwnersAvatar() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try checkout(fixture)
        let fetched = Touches()
        let avatars = AgentPaneOwnerAvatars(folder: nil, fetch: { url in fetched.add(url.absoluteString); return Self.png })
        let icons = AgentPaneProjectIcons(reader: fixture.icons, repos: fixture.repos, avatars: avatars)
        #expect(await icons.answer(for: fixture.home + "/wt/cmux/picker").src == "data:image/png;base64," + Self.png.base64EncodedString())
        #expect(fetched.all == ["https://github.com/manaflow-ai.png?size=64"])
    }

    /// Leo 2026-10-21: "why are the project icons not showing up for SOME of the cmux...? only one
    /// has my github icon?" Every clone and worktree of a GitHub repository wears its owner's avatar,
    /// an organization's too, ahead of an icon file it happens to have.
    @Test func theOwnersAvatarComesBeforeTheProjectsOwnIconFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try checkout(fixture)
        try fixture.write(Data([0x89, 0x50, 0x4E, 0x47, 1]), "code/cmux/favicon.png")
        let fetched = Touches()
        let avatars = AgentPaneOwnerAvatars(folder: nil, fetch: { url in fetched.add(url.absoluteString); return Self.png })
        let icons = AgentPaneProjectIcons(reader: fixture.icons, repos: fixture.repos, avatars: avatars)
        let avatar = "data:image/png;base64," + Self.png.base64EncodedString()
        #expect(await icons.answer(for: fixture.home + "/code/cmux").src == avatar)
        #expect(await icons.answer(for: fixture.home + "/wt/cmux/picker").src == avatar)
        #expect(fetched.all == ["https://github.com/manaflow-ai.png?size=64"])
    }

    @Test func withNoAvatarTheProjectsOwnIconFileIsDrawn() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try checkout(fixture)
        let own = Data([0x89, 0x50, 0x4E, 0x47, 1])
        try fixture.write(own, "code/cmux/favicon.png")
        let icons = AgentPaneProjectIcons(reader: fixture.icons, repos: fixture.repos,
                                          avatars: AgentPaneOwnerAvatars(folder: nil, fetch: { _ in nil }))
        #expect(await icons.answer(for: fixture.home + "/code/cmux").src == "data:image/png;base64," + own.base64EncodedString())
    }

    /// A lane mirror (`.wt-mirrors/manaflow-ai/cmux.git`) is a bare repository: a chat in it belongs
    /// to its GitHub repository, so it folds with the other clones and draws the owner's avatar.
    @Test func aBareMirrorIsItsGitHubRepository() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("ref: refs/heads/main\n", "mirrors/cmux.git/HEAD")
        try fixture.write(Self.githubConfig.replacingOccurrences(of: "bare = false", with: "bare = true"), "mirrors/cmux.git/config")
        let repo = fixture.repos.repo(for: fixture.home + "/mirrors/cmux.git")
        #expect(repo?.github == "manaflow-ai/cmux")
        #expect(repo?.name == "cmux")
        #expect(repo?.root == fixture.home + "/mirrors/cmux.git")
        // A folder that only looks like one (no `bare = true`) is no repository.
        try fixture.write("ref: refs/heads/main\n", "notes/HEAD")
        try fixture.write("[core]\n\tbare = false\n", "notes/config")
        #expect(fixture.repos.repo(for: fixture.home + "/notes") == nil)
    }

    @Test func anAvatarIsFetchedOnceAndKeptOnDiskForAWeek() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = URL(fileURLWithPath: fixture.home + "/avatars")
        let fetched = Touches()
        let fetch: AgentPaneOwnerAvatars.Fetch = { url in fetched.add(url.absoluteString); return Self.png }
        let first = AgentPaneOwnerAvatars(folder: folder, fetch: fetch)
        let src = await first.avatar(for: "manaflow-ai")
        #expect(src == "data:image/png;base64," + Self.png.base64EncodedString())
        #expect(await first.avatar(for: "manaflow-ai") == src)
        #expect(fetched.all.count == 1)

        // The next launch reads the disk.
        #expect(await AgentPaneOwnerAvatars(folder: folder, fetch: fetch).avatar(for: "manaflow-ai") == src)
        #expect(fetched.all.count == 1)

        // A week later it is fetched again.
        let later = AgentPaneOwnerAvatars(folder: folder, fetch: fetch, now: { Date().addingTimeInterval(8 * 24 * 60 * 60) })
        #expect(await later.avatar(for: "manaflow-ai") == src)
        #expect(fetched.all.count == 2)
    }

    @Test func aFailedAvatarIsKeptForAMinuteOnlyAndABadOwnerIsNeverFetched() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = URL(fileURLWithPath: fixture.home + "/avatars")
        let fetched = Touches()
        let avatars = AgentPaneOwnerAvatars(folder: folder, fetch: { url in fetched.add(url.absoluteString); return Data("<html>".utf8) })
        #expect(await avatars.avatar(for: "nobody") == nil)
        #expect(await avatars.avatar(for: "nobody") == nil)
        #expect(fetched.all.count == 1)
        #expect(!FileManager.default.fileExists(atPath: folder.path + "/nobody"))
        #expect(await avatars.avatar(for: "../etc") == nil)
        #expect(await avatars.avatar(for: "a/b") == nil)
        #expect(fetched.all.count == 1)
    }

    /// Leo 2026-10-28, on the project menu: "why are there so many default icons?" One miss (offline
    /// at launch, a timeout) left every repository of that owner on the plain folder until the app
    /// relaunched; a minute later the owner is asked again, and a picture that arrives stays.
    @Test func aFailedAvatarIsFetchedAgainAfterAMinute() async throws {
        let fetched = Touches()
        let online = Touches()
        let clock = SteppedDate()
        let avatars = AgentPaneOwnerAvatars(folder: nil, fetch: { url in
            fetched.add(url.absoluteString)
            return online.all.isEmpty ? nil : Self.png
        }, now: { clock.date })
        #expect(await avatars.avatar(for: "manaflow-ai") == nil)
        #expect(await avatars.avatar(for: "manaflow-ai") == nil)
        #expect(fetched.all.count == 1)

        online.add("up")
        clock.advance(61)
        let src = "data:image/png;base64," + Self.png.base64EncodedString()
        #expect(await avatars.avatar(for: "manaflow-ai") == src)
        clock.advance(61)
        #expect(await avatars.avatar(for: "manaflow-ai") == src)
        #expect(fetched.all.count == 2)
    }

    /// `project.list` answers each listed folder's repository beside the paths.
    @MainActor
    @Test func theProjectListCarriesEachFoldersRepository() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try checkout(fixture)
        let worktree = fixture.home + "/wt/cmux/picker"
        let model = AgentPaneModel(host: NoHost())
        model.onListProjects = { _ in [worktree] }
        let value = (await model.respond(to: .listProjects(nil)))["value"] as? [String: Any]
        #expect(value?["projects"] as? [String] == [worktree])
        let repo = (value?["repos"] as? [String: Any])?[worktree] as? [String: Any]
        #expect(repo?["root"] as? String == fixture.home + "/code/cmux")
        #expect(repo?["top"] as? String == worktree)
        #expect(repo?["name"] as? String == "cmux")
        #expect(repo?["branch"] as? String == "feat/picker")
        #expect(repo?["github"] as? String == "manaflow-ai/cmux")
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }
}
