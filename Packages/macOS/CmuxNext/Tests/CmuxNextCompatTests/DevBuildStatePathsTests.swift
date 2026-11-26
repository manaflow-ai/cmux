import CmuxNextCompat
import Foundation
import Testing

/// The user, 2026-11-16: "for dev builds we must make sure that all such values and configurations have a dev build
/// isolation that prevents each dev build from deriving state from each other even from prod." Every path
/// ``BuildStatePaths`` resolves for a DEV build is its own (never NIGHTLY's, stable's or another tag's), and every
/// other build's paths are exactly the shared ones it had before.
@Suite struct DevBuildStatePathsTests {
    static let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    static let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
    static let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)

    static func paths(_ bundleID: String?, tag: String? = nil) -> BuildStatePaths {
        BuildStatePaths(build: BuildIdentity(bundleID: bundleID, bundledTag: tag), userHome: home,
                        applicationSupport: support, caches: caches)
    }

    static let nightly = paths("com.cmuxterm.app.nightly")
    static let dev = paths("com.cmuxterm.app.debug.my-tag")
    static let otherTag = paths("com.cmuxterm.app.debug.other-tag")

    /// Each path a DEV build resolves differs from NIGHTLY's and another tag's, and lies outside `~/.config/cmux` and
    /// every shared folder.
    @Test func aDevBuildsPathsAreItsOwn() throws {
        let shared = Self.nightly.all.map(\.url.path)
        let other = Self.otherTag.all.map(\.url.path)
        for (name, url) in Self.dev.all {
            #expect(!shared.contains(url.path), "\(name) is nightly's: \(url.path)")
            #expect(!other.contains(url.path), "\(name) is another tag's: \(url.path)")
            #expect(!url.path.hasPrefix(Self.home.path + "/.config/cmux"), "\(name) is in the shared config folder")
            #expect(url.path.contains("/builds/com.cmuxterm.app.debug.my-tag"), "\(name) is outside the build's folder: \(url.path)")
        }
        let root = try #require(Self.dev.ownRoot)
        #expect(root.path == Self.support.path + "/cmux-next/builds/com.cmuxterm.app.debug.my-tag")
        #expect(Self.dev.settingsFile.path == root.path + "/config/cmux-next.json")
    }

    /// Every DEV form isolates: a tagged reload build, the untagged DEV bundle, a DEV bundle that ships a tag, an
    /// unknown `com.cmuxterm.app.*` bundle and a tagged staging build; two builds of one id with other tags too.
    @Test func everyDevFormIsolates() {
        let forms = [Self.paths("com.cmuxterm.app.debug"), Self.paths("com.cmuxterm.app.debug", tag: "shipped"),
                     Self.paths("com.cmuxterm.app.debug", tag: "shipped-2"), Self.paths("com.cmuxterm.app.experiment"),
                     Self.paths("com.cmuxterm.app.staging.my-tag"), Self.dev]
        for form in forms {
            #expect(form.isolatesSharedState, "\(form.build.key)")
            #expect(form.settingsFile != Self.nightly.settingsFile, "\(form.build.key)")
            #expect(!form.importsOtherBuildsPreferences, "\(form.build.key)")
        }
        #expect(Set(forms.map(\.settingsFile)).count == forms.count, "two DEV builds share a settings file")
    }

    /// NIGHTLY, cmux NEXT, RC, release, untagged staging and a process outside any bundle share NEXT's own roots
    /// (never classic cmux's `~/.config/cmux`, Application Support or Caches `cmux`), byte for byte, and set
    /// nothing in their children's environment (Rust's defaults name the same paths).
    @Test func sharedBuildsKeepTheirPaths() {
        for build in [Self.nightly, Self.paths("com.cmuxterm.app.nightly.cmux-next"), Self.paths("com.cmuxterm.app.rc"),
                      Self.paths("com.cmuxterm.app"), Self.paths("com.cmuxterm.app.staging"), Self.paths(nil)] {
            #expect(!build.isolatesSharedState, "\(build.build.key)")
            #expect(build.ownRoot == nil)
            #expect(build.environment.isEmpty, "\(build.build.key) points its children elsewhere")
            #expect(build.importsOtherBuildsPreferences)
            #expect(build.cloudSecretsService == "cmux-cloud-secret")
            let paths = Dictionary(uniqueKeysWithValues: build.all.map { ($0.name, $0.url.path) })
            #expect(paths == [
                "configDirectory": "/Users/me/.config/cmux-next",
                "settingsFile": "/Users/me/.config/cmux-next/cmux-next.json",
                "cloudSecretsIndex": "/Users/me/.config/cmux-next/cloud-secrets.json",
                "hostBudgetFile": "/Users/me/.config/cmux-next/host-budget.json",
                "keysAuditFile": "/Users/me/.config/cmux-next/keys.json",
                "automationsDirectory": "/Users/me/.config/cmux-next/automations",
                "customizeDirectory": "/Users/me/.config/cmux-next/customize",
                "agentSkillsDirectory": "/Users/me/.config/cmux-next/skills",
                "agentCommandsDirectory": "/Users/me/.config/cmux-next/commands",
                "githubWorktrees": "/Users/me/.config/cmux-next/github-worktrees",
                "recoveryDrafts": "/Users/me/Library/Application Support/cmux-next/recovery",
                "agentHome": "/Users/me/Library/Application Support/cmux-next/agent-home",
                "chatUploads": "/Users/me/Library/Application Support/cmux-next/Chat Uploads",
                "projectAvatarsCache": "/Users/me/Library/Caches/cmux-next/project-avatars",
                "shellCompletionCache": "/Users/me/Library/Caches/cmux-next",
                "homeCachesRoot": "/Users/me/Library/Caches",
            ], "\(build.build.key)")
            for (name, url) in build.all {
                for classic in ["/Users/me/.config/cmux/", "/Users/me/Library/Application Support/cmux/", "/Users/me/Library/Caches/cmux/"] {
                    #expect(!(url.path + "/").hasPrefix(classic), "\(name) is under classic's \(classic)")
                }
            }
        }
    }

    /// A DEV build's children (daemon, acpmux, the `cmux` CLI) read its own files: one variable per file, each
    /// naming the DEV path.
    @Test func aDevBuildsChildrenReadItsFiles() {
        let environment = Self.dev.environment
        #expect(Set(environment.keys) == Set(BuildStatePaths.environmentKeys))
        #expect(environment["CMUX_NEXT_CONFIG_FILE"] == Self.dev.settingsFile.path)
        #expect(environment["CMUX_NEXT_CLOUD_SECRETS_FILE"] == Self.dev.cloudSecretsIndex.path)
        #expect(environment["CMUX_NEXT_KEYS_AUDIT_FILE"] == Self.dev.keysAuditFile.path)
        #expect(environment["ACPMUX_HOST_BUDGET"] == Self.dev.hostBudgetFile.path)
        #expect(environment["CMUX_AUTOMATIONS_DIR"] == Self.dev.automationsDirectory.path)
        #expect(environment["CMUX_CUSTOMIZE_DIR"] == Self.dev.customizeDirectory.path)
        #expect(environment["CMUX_AGENT_SKILLS_DIR"] == Self.dev.agentSkillsDirectory.path)
        #expect(environment["CMUX_COMMANDS_DIR"] == Self.dev.agentCommandsDirectory.path)
        #expect(environment["CMUX_NEXT_CLOUD_SECRETS_SERVICE"] == "cmux-cloud-secret.com.cmuxterm.app.debug.my-tag")
        #expect(Self.otherTag.cloudSecretsService != Self.dev.cloudSecretsService)
        #expect(environment.values.allSatisfy { !$0.contains("/.config/cmux") })
    }

    /// At launch the app sets each variable it does not already have: an explicit test override
    /// (`--config-file`, `CMUX_NEXT_CONFIG_FILE` from a harness) keeps its file.
    @Test func launchKeepsAnExplicitOverride() {
        let set = Self.dev.launchEnvironment(over: ["CMUX_NEXT_CONFIG_FILE": "/tmp/test.json", "PATH": "/usr/bin"])
        #expect(set["CMUX_NEXT_CONFIG_FILE"] == nil)
        #expect(set["CMUX_NEXT_CLOUD_SECRETS_FILE"] == Self.dev.cloudSecretsIndex.path)
        #expect(Self.nightly.launchEnvironment(over: [:]).isEmpty)
    }

    /// A child whose environment is an allow list gets exactly these variables from the app's.
    @Test func childEnvironmentPassesOnlyTheFiles() {
        let process = Self.dev.environment.merging(["PATH": "/usr/bin", "CMUX_NEXT_CHIEF_HOME": "/x"]) { $1 }
        #expect(BuildStatePaths.childEnvironment(from: process) == Self.dev.environment)
        #expect(BuildStatePaths.childEnvironment(from: ["PATH": "/usr/bin"]).isEmpty)
    }

    /// The Swift readers of the Cloud secrets index and Keychain service follow the variables, as Rust's do.
    @Test func cloudSecretsFollowTheVariables() {
        #expect(BuildStatePaths.cloudSecretsIndex(environment: Self.dev.environment, home: Self.home) == Self.dev.cloudSecretsIndex)
        #expect(BuildStatePaths.cloudSecretsIndex(environment: [:], home: Self.home) == Self.nightly.cloudSecretsIndex)
        #expect(BuildStatePaths.cloudSecretsService(environment: Self.dev.environment) == Self.dev.cloudSecretsService)
        #expect(BuildStatePaths.cloudSecretsService(environment: [:]) == "cmux-cloud-secret")
    }
}
