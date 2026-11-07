import Foundation

/// The last login environment the app captured, kept on disk so the next
/// launch has it before `$SHELL -l -i` finishes (5-17 s on some setups).
///
/// Only the `TerminalEnvironment` allowlist is written (`PATH`, `LANG`,
/// `LC_*`, `HOMEBREW_*` and similar, never a credential): the same subset
/// the daemon and every terminal receive anyway. The file is private to the
/// user (0600).
///
/// It is per user, not per tag: the capture seeds only `HOME`, `USER`,
/// `LOGNAME`, `LANG`, `TMPDIR` and `SHELL`, so every build and tag of the
/// app captures the same environment, and a new dogfood tag starts with it
/// on its first launch.
struct LoginEnvironmentStore: Sendable {
    private let read: @Sendable () -> Data?
    private let write: @Sendable (Data) -> Void

    /// `read` returns the file's bytes (nil when missing); `write` replaces them.
    init(read: @escaping @Sendable () -> Data?, write: @escaping @Sendable (Data) -> Void) {
        self.read = read
        self.write = write
    }

    /// A store in `url`, written atomically and made private to the user.
    static func file(_ url: URL) -> LoginEnvironmentStore {
        LoginEnvironmentStore(read: { try? Data(contentsOf: url) }, write: { data in
            let fileManager = FileManager.default
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? data.write(to: url, options: .atomic)) != nil else { return }
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        })
    }

    /// `~/Library/Application Support/cmux/login-environment.json`.
    static func standard() -> LoginEnvironmentStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return file(support.appendingPathComponent("cmux/login-environment.json"))
    }

    /// The remembered environment, or nil when there is none, it cannot be
    /// read, it is another version, or it has no `PATH` (cmux-daemon-launch-core `login_store_decode`, which
    /// filters it again).
    func load() -> [String: String]? {
        guard let data = read() else { return nil }
        let text = DaemonLaunchRules.Text(text: String(decoding: data, as: UTF8.self))
        return DaemonLaunchRules.call("login_store_decode", text, as: [String: String]?.self) ?? nil
    }

    /// Remembers the allowlisted part of `environment` (`login_store_encode`); nothing without a `PATH`.
    func save(_ environment: [String: String]) {
        let record = DaemonLaunchRules.call("login_store_encode", DaemonLaunchRules.Environment(environment: environment),
                                            as: String?.self) ?? nil
        guard let record else { return }
        write(Data(record.utf8))
    }
}
