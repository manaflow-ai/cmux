import Foundation

/// Where Chromium looks for native messaging host manifests
/// (`chrome.runtime.connectNative`), in order:
///
/// 1. cmux's own Chromium user data folder,
///    `~/Library/Application Support/<bundle id>/Chromium/NativeMessagingHosts`
///    (Chromium's user-level folder).
/// 2. `/Library/Application Support/Chromium/NativeMessagingHosts`
///    (Chromium's system folder).
/// 3. Google Chrome's user folder,
///    `~/Library/Application Support/Google/Chrome/NativeMessagingHosts`.
/// 4. Google Chrome's system folder, `/Library/Google/Chrome/NativeMessagingHosts`.
///
/// 3 and 4 (fork API 12, user decision 2026-09-30) let desktop apps that
/// register only for Google Chrome (1Password, Bitwarden) connect. A host's
/// manifest still lists the extension ids it allows (`allowed_origins`), so
/// only those extensions reach it. The first folder with the host's manifest
/// wins; user-level folders are skipped when policy disallows user-level
/// hosts (Chromium's rule).
nonisolated enum CEFNativeMessaging {
    struct Folder: Equatable {
        var path: String
        var isUserLevel: Bool
    }

    /// The folders cmux adds after Chromium's own two.
    static func googleChromeFolders(home: URL) -> [Folder] {
        [
            Folder(path: home.appending(path: "Library/Application Support/Google/Chrome/NativeMessagingHosts").path,
                   isUserLevel: true),
            Folder(path: "/Library/Google/Chrome/NativeMessagingHosts", isUserLevel: false),
        ]
    }
}
