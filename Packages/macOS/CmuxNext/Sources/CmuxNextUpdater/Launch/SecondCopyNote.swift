public import Foundation

/// The note a second copy's hand-off sends the running copy (``SingleInstanceHandoff``): which bundle was opened,
/// and the URLs LaunchServices could not deliver. A distributed notification named ``name`` whose object is the
/// bundle id, so only copies of the same app hear it. Any local process could post one, as it could run
/// `open -a cmux <url>`: the URLs are handled as an open of them would be, and the switch it may offer goes only to
/// a bundle with this app's id and signing team (``AppCopyGuide``).
public nonisolated struct SecondCopyNote: Equatable, Sendable {
    public static let name = "com.cmuxterm.next.secondCopyOpened"

    /// The opened copy's bundle.
    public var openedPath: String
    /// URLs the hand-off could not give LaunchServices (the running copy's bundle is gone, or its owner record
    /// never resolved); they open in the running copy instead of being dropped.
    public var urls: [URL]

    public init(openedPath: String, urls: [URL] = []) {
        self.openedPath = openedPath
        self.urls = urls
    }

    /// The notification's user info: plist values only.
    public var userInfo: [String: Any] {
        ["path": openedPath, "urls": urls.map { $0.isFileURL ? $0.path : $0.absoluteString }]
    }

    public init?(userInfo: [AnyHashable: Any]?) {
        guard let path = userInfo?["path"] as? String, path.hasPrefix("/") else { return nil }
        let texts = (userInfo?["urls"] as? [String] ?? []).prefix(256)
        self.init(openedPath: path, urls: texts.compactMap { $0.hasPrefix("/") ? URL(filePath: $0) : URL(string: $0) })
    }

    /// Posts this note to the running copies of `bundleIdentifier`, delivered at once even when that copy is in
    /// the background.
    public func post(bundleIdentifier: String) {
        let object = bundleIdentifier as CFString
        withExtendedLifetime(object) {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDistributedCenter(),
                                                 CFNotificationName(Self.name as CFString), Self.pointer(object),
                                                 userInfo as CFDictionary, true)
        }
    }

    /// A CF object as the `object` argument of the distributed center (which takes, and copies, a CFString).
    static func pointer(_ object: CFString) -> UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(object).toOpaque())
    }
}
