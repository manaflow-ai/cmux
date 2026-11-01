import AppKit
import CmuxNextCompat
import Darwin
public import Foundation

/// What a file's own metadata says it came from (``AttachmentSource``), read off the main actor:
///
/// - cmux's mark (``ownMark``), which cmux sets on the files it writes (Screenshot Tab): cmux.
/// - A screen capture's or screen recording's metadata (`kMDItemIsScreenCapture`,
///   `kMDItemIsScreenRecording`, `kMDItemScreenCaptureType`), which macOS's Screenshot sets: Screenshot.
/// - The quarantine record a download carries, whose agent LaunchServices names by bundle
///   identifier (`kLSQuarantineAgentBundleIdentifierKey`): that app, with the host of the page it
///   came from (`kMDItemWhereFroms`, else the record's own URLs). AirDrop's agent, `sharingd`, is
///   AirDrop. An agent that is no installed app (a command-line tool) is no source.
///
/// `kMDItemCreator` is not read: it names whatever wrote the document (a PDF library, "Quartz
/// PDFContext"), not an app, and a source is never a guess.
nonisolated extension AttachmentSource {
    /// The extended attribute cmux sets on the files it writes; its value is cmux's bundle identifier.
    public static let ownMark = "com.cmuxterm.attachment-source"
    static let screenCaptureMarks = [
        "com.apple.metadata:kMDItemIsScreenCapture",
        "com.apple.metadata:kMDItemIsScreenRecording",
        "com.apple.metadata:kMDItemScreenCaptureType",
    ]
    static let whereFroms = "com.apple.metadata:kMDItemWhereFroms"
    /// AirDrop's daemon, the quarantine agent of what AirDrop brings in.
    static let airDropAgent = "com.apple.sharingd"
    static let airDropApp = "com.apple.finder.Open-AirDrop"

    /// Writes `data`, a capture cmux took, to `url` (its folder made first, atomically) and marks it
    /// as cmux's (``markOwn(_:bundleId:)``), so an attachment made of it wears cmux's icon. A
    /// blocking file write: call it off the main actor.
    public static func writeOwn(_ data: Data, to url: URL) throws {
        try FileManager.checked.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.blockingWrite(to: url, options: .atomic)
        markOwn(url)
    }

    /// Marks `url`, a file cmux wrote, as cmux's (Screenshot Tab's PNG). Best effort.
    public static func markOwn(_ url: URL, bundleId: String? = Bundle.main.bundleIdentifier) {
        guard let bundleId, AttachmentSource.isBundleId(bundleId) else { return }
        let bytes = Array(bundleId.utf8)
        _ = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return setxattr(path, ownMark, bytes, bytes.count, 0, 0)
        }
    }

    /// Where the file at `url` came from, or nil when its metadata does not say.
    public static func source(of url: URL, apps: AttachmentSourceApps = .live) -> AttachmentSource? {
        let read = { (name: String) in attribute(name, of: url) }
        let quarantine = (try? url.blockingResourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties
        return source(attribute: read, quarantine: quarantine, apps: apps)
    }

    /// ``source(of:apps:)`` over a file's attributes (`attribute`, raw bytes by name) and its
    /// quarantine record.
    static func source(attribute: (String) -> Data?, quarantine: [String: Any]?, apps: AttachmentSourceApps) -> AttachmentSource? {
        if let mark = attribute(ownMark).flatMap({ String(data: $0, encoding: .utf8) }),
           mark == apps.ownBundleId() {
            return .cmux
        }
        if screenCaptureMarks.contains(where: { attribute($0) != nil }) {
            return apps.app(AttachmentSource.screenshotBundleId) != nil ? .screenshot : nil
        }
        guard let quarantine,
              let agent = quarantine[kLSQuarantineAgentBundleIdentifierKey as String] as? String else { return nil }
        let bundleId = agent == airDropAgent ? airDropApp : agent
        guard AttachmentSource.isBundleId(bundleId), let name = apps.app(bundleId) else { return nil }
        let site = site(whereFroms: attribute(whereFroms), quarantine: quarantine)
        return AttachmentSource(name: name, bundleId: bundleId, site: site)
            ?? AttachmentSource(name: name, bundleId: bundleId)
    }

    /// The host of the page a download came from: the last web URL of `kMDItemWhereFroms` (a
    /// binary plist of strings, the file's own URL first, then the page it was on), else the
    /// quarantine record's origin (the page) or data URL (the file).
    static func site(whereFroms: Data?, quarantine: [String: Any]) -> String? {
        let listed = whereFroms.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String] ?? []
        let recorded = [kLSQuarantineOriginURLKey, kLSQuarantineDataURLKey].compactMap { key -> String? in
            let value = quarantine[key as String]
            return (value as? URL)?.absoluteString ?? value as? String
        }
        for candidate in listed.reversed() + recorded {
            guard let url = URL(string: candidate), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host(percentEncoded: false)?.lowercased(), AttachmentSource.isSite(host) else { continue }
            return host
        }
        return nil
    }

    /// The bytes of extended attribute `name` of the file at `url` (its link, not where it points),
    /// or nil when it has none. Larger than 64 KB is none: no attribute read here is that large.
    static func attribute(_ name: String, of url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0, size <= 64 * 1024 else { return nil }
            var bytes = [UInt8](repeating: 0, count: size)
            let read = getxattr(path, name, &bytes, size, 0, XATTR_NOFOLLOW)
            return read >= 0 ? Data(bytes.prefix(read)) : nil
        }
    }
}

/// The installed apps a source may name, by bundle identifier (tests stand in their own).
public nonisolated struct AttachmentSourceApps: Sendable {
    /// The display name of the installed app `bundleId` names, or nil when none is installed.
    public var app: @Sendable (String) -> String?
    /// This app's bundle identifier.
    public var ownBundleId: @Sendable () -> String?

    public init(app: @escaping @Sendable (String) -> String?, ownBundleId: @escaping @Sendable () -> String?) {
        (self.app, self.ownBundleId) = (app, ownBundleId)
    }

    public static let live = AttachmentSourceApps(
        app: { bundleId in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        },
        ownBundleId: { Bundle.main.bundleIdentifier })
}
