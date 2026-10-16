import Foundation

/// A minimal inherited environment for sudo-broker helper processes.
struct SudoProcessEnvironment: Sendable {
    private static let allowedKeys: Set<String> = [
        "HOME",
        "LANG",
        "LC_ALL",
        "LC_ADDRESS",
        "LC_COLLATE",
        "LC_CTYPE",
        "LC_IDENTIFICATION",
        "LC_MEASUREMENT",
        "LC_MESSAGES",
        "LC_MONETARY",
        "LC_NAME",
        "LC_NUMERIC",
        "LC_PAPER",
        "LC_TELEPHONE",
        "LC_TIME",
        "LOGNAME",
        "PATH",
        "SHELL",
        "TERM",
        "TMPDIR",
        "USER",
        "__CF_USER_TEXT_ENCODING",
    ]

    let entries: [String]

    init(inherited: [String: String] = ProcessInfo.processInfo.environment) {
        var selected = inherited.filter { key, value in
            Self.allowedKeys.contains(key)
                && !key.utf8.contains(0)
                && !value.utf8.contains(0)
        }
        selected["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        entries = selected.map { "\($0.key)=\($0.value)" }.sorted()
    }
}
