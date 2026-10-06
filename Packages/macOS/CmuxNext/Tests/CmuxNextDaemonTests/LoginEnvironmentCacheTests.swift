import Foundation
import Testing
@testable import CmuxNextDaemon

/// A cold launch must not wait for the login shell (`$SHELL -l -i`, 5-17 s
/// on some setups) before it starts the daemon, and terminals must still get
/// the login environment: the remembered copy at once, else the capture.
@Suite struct LoginEnvironmentCacheTests {
    let finder = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/u", "TMPDIR": "/var/folders/xx/T/"]
    let login = ["PATH": "/opt/homebrew/bin:/Users/u/.cargo/bin:/usr/bin:/bin", "SHELL": "/bin/zsh", "LANG": "en_US.UTF-8"]

    @Test(.timeLimit(.minutes(1))) func theDaemonStartsWithoutWaitingForTheLoginShell() async {
        let shell = SlowLoginShell()
        defer { shell.close() }
        let cache = LoginEnvironmentCache(store: MemoryLoginEnvironmentFile().store, capture: { await shell.capture($0) })
        let environment = await DaemonLauncher.appEnvironment(cache: cache, base: finder, overrides: ["CMUX_TAG": "t"])()
        // Nothing remembered: the app's own environment, as when capture fails.
        #expect(environment["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["HOME"] == "/Users/u")
        #expect(environment["CMUX_TAG"] == "t")
    }

    @Test(.timeLimit(.minutes(1))) func theDaemonStartsWithTheRememberedEnvironment() async {
        let shell = SlowLoginShell()
        defer { shell.close() }
        let file = MemoryLoginEnvironmentFile(remembering: login)
        let cache = LoginEnvironmentCache(store: file.store, capture: { await shell.capture($0) })
        let environment = await DaemonLauncher.appEnvironment(cache: cache, base: finder, overrides: [:])()
        #expect(environment["PATH"] == login["PATH"])
        #expect(environment["LANG"] == "en_US.UTF-8")
    }

    @Test(.timeLimit(.minutes(1))) func terminalsUseTheRememberedEnvironmentWithoutWaiting() async {
        let shell = SlowLoginShell()
        defer { shell.close() }
        let cache = LoginEnvironmentCache(store: MemoryLoginEnvironmentFile(remembering: login).store, capture: { await shell.capture($0) })
        let terminal = await TerminalEnvironment.instance.shared(base: finder, login: { await cache.value() })()
        #expect(terminal["PATH"] == login["PATH"])
    }

    @Test(.timeLimit(.minutes(1))) func terminalsWaitForTheLoginShellWhenNothingIsRemembered() async {
        let shell = SlowLoginShell()
        defer { shell.close() }
        let cache = LoginEnvironmentCache(store: MemoryLoginEnvironmentFile().store, capture: { await shell.capture($0) })
        let provider = TerminalEnvironment.instance.shared(base: finder, login: { await cache.value() })
        async let terminal = provider()
        shell.answer(login)
        #expect(await terminal["PATH"] == login["PATH"])
        #expect(shell.capturedDeadlines == [.seconds(5)])
    }

    @Test(.timeLimit(.minutes(1))) func aFreshCaptureReplacesTheRememberedOneAndIsSavedWithoutSecrets() async {
        let shell = SlowLoginShell()
        defer { shell.close() }
        let file = MemoryLoginEnvironmentFile(remembering: ["PATH": "/old/bin:/usr/bin"])
        let cache = LoginEnvironmentCache(store: file.store, capture: { await shell.capture($0) })
        await cache.start()
        var fresh = login
        fresh["GITHUB_TOKEN"] = "ghp_secret"
        fresh["AWS_SECRET_ACCESS_KEY"] = "aws-secret"
        fresh["CMUX_SOCKET_PASSWORD"] = "pw"
        shell.answer(fresh)
        await file.nextWrite()
        #expect(await cache.value()?["PATH"] == login["PATH"])
        #expect(await cache.immediate()?["PATH"] == login["PATH"])
        #expect(!file.text.contains("secret"))
        #expect(!file.text.contains("\"pw\""))
        // The next launch starts with it.
        let next = LoginEnvironmentCache(store: file.store, capture: { _ in nil })
        #expect(await next.immediate() == login)
    }

    /// A shell slower than the 5 s a waiting terminal allows still fills the
    /// remembered copy: a second capture with a longer deadline runs in the
    /// background, and later terminals and the next launch get its result.
    @Test(.timeLimit(.minutes(1))) func aTimedOutCaptureIsRetriedInTheBackgroundWithALongerDeadline() async {
        let shell = SlowLoginShell()
        defer { shell.close() }
        let file = MemoryLoginEnvironmentFile()
        let cache = LoginEnvironmentCache(store: file.store, waitTimeout: .seconds(5), refreshTimeout: .seconds(30),
                                          capture: { await shell.capture($0) })
        async let first = cache.value()
        shell.answer(nil)
        #expect(await first == nil)
        shell.answer(login)
        await file.nextWrite()
        #expect(shell.capturedDeadlines == [.seconds(5), .seconds(30)])
        #expect(await cache.value()?["PATH"] == login["PATH"])
        #expect(file.store.load()?["PATH"] == login["PATH"])
    }

    @Test func theStoreKeepsOnlyTheAllowlistAndRejectsBadFiles() {
        let file = MemoryLoginEnvironmentFile()
        file.store.save(["PATH": "/usr/bin", "OPENAI_API_KEY": "sk-1", "HOMEBREW_PREFIX": "/opt/homebrew", "PWD": "/x"])
        #expect(file.store.load() == ["PATH": "/usr/bin", "HOMEBREW_PREFIX": "/opt/homebrew"])
        #expect(LoginEnvironmentStore(read: { Data("not json".utf8) }, write: { _ in }).load() == nil)
        #expect(LoginEnvironmentStore(read: { nil }, write: { _ in }).load() == nil)
        let future = Data(#"{"version":99,"environment":{"PATH":"/usr/bin"}}"#.utf8)
        #expect(LoginEnvironmentStore(read: { future }, write: { _ in }).load() == nil)
        let noPath = MemoryLoginEnvironmentFile()
        noPath.store.save(["LANG": "C"])
        #expect(noPath.text.isEmpty, "an environment without PATH is not remembered")
    }

    @Test func theStoreFileIsPrivateToTheUser() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("login-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cmux/login-environment.json")
        let store = LoginEnvironmentStore.file(url)
        store.save(login)
        #expect(store.load()?["PATH"] == login["PATH"])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
