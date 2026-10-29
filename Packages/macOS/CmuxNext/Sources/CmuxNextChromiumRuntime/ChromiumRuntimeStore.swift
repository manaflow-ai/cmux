public import Foundation
import CmuxNextCompat

/// The on-disk home of downloaded Chromium runtime packs:
///
///     <root>/<key>/<folder>/            an installed pack (framework, shim, helpers)
///     <root>/<key>/installed.json       written last: the install is complete
///     <root>/.downloads/<key>.tar.xz.partial
///     <root>/.staging-<uuid>/           an unpack in progress
///
/// The root is `~/Library/Application Support/<bundle id>/ChromiumRuntime`
/// in the app (``defaultRoot(applicationSupport:bundleIdentifier:)``) and a
/// temporary folder in tests. Every method is synchronous file work; call it
/// off the main thread (``ChromiumRuntimeInstaller`` does).
public struct ChromiumRuntimeStore: Sendable, Equatable {
    /// The folder that holds every pack.
    public let root: URL

    /// Creates a store rooted at `root` (created on first write).
    public init(root: URL) {
        self.root = root
    }

    /// `<applicationSupport>/<bundleIdentifier>/ChromiumRuntime`.
    ///
    /// - Parameters:
    ///   - applicationSupport: The user's Application Support folder.
    ///   - bundleIdentifier: The app's bundle id (each channel has its own packs).
    public static func defaultRoot(applicationSupport: URL, bundleIdentifier: String) -> URL {
        applicationSupport.appending(path: bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "ChromiumRuntime", directoryHint: .isDirectory)
    }

    /// Every complete installation, newest record first.
    public func installations() -> [ChromiumRuntimeInstallation] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().compactMap(installation(key:))
            .sorted { modified($0) > modified($1) }
    }

    /// The complete installation of `key`, nil when there is none (or its
    /// record does not match its folder).
    public func installation(key: String) -> ChromiumRuntimeInstallation? {
        let directory = root.appending(path: key, directoryHint: .isDirectory)
        guard let data = try? Data(contentsOf: directory.appending(path: ChromiumRuntimeInstallation.recordName)),
              let pin = try? ChromiumRuntimePin.decode(data), pin.key == key else { return nil }
        let installation = ChromiumRuntimeInstallation(pin: pin, directory: directory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: installation.frameworksDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return installation
    }

    /// The runtime this launch uses for an app pinned to `pin`: the pinned
    /// pack, else the newest compatible one (same shim ABI, folder and
    /// team), else none.
    public func select(for pin: ChromiumRuntimePin) -> ChromiumRuntimeSelection {
        if let exact = installation(key: pin.key) { return .exact(exact) }
        let compatible = installations().first {
            $0.pin.shimABI == pin.shimABI && $0.pin.folder == pin.folder && $0.pin.teamID == pin.teamID
        }
        return compatible.map(ChromiumRuntimeSelection.compatible) ?? .none
    }

    /// Where the download of `pin` is kept between attempts and launches.
    public func partialFile(for pin: ChromiumRuntimePin) -> URL {
        root.appending(path: ".downloads", directoryHint: .isDirectory).appending(path: "\(pin.key).tar.xz.partial")
    }

    /// A new empty folder to unpack into.
    public func makeStagingDirectory() throws -> URL {
        let staging = root.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    /// Moves a verified unpack into `<root>/<key>/` and writes its record
    /// last, so a crash leaves either nothing or a complete install.
    ///
    /// - Parameters:
    ///   - staging: The folder ``makeStagingDirectory()`` made, holding the runtime folder.
    ///   - pin: The pin the pack was verified against.
    /// - Returns: The new installation.
    public func activate(staging: URL, pin: ChromiumRuntimePin) throws -> ChromiumRuntimeInstallation {
        let directory = root.appending(path: pin.key, directoryHint: .isDirectory)
        if FileManager.checked.fileExists(atPath: directory.path) {
            // An unfinished install (no record) from an earlier crash.
            try FileManager.checked.removeItem(at: directory)
        }
        try FileManager.checked.moveItem(at: staging, to: directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(pin).write(to: directory.appending(path: ChromiumRuntimeInstallation.recordName), options: .atomic)
        return ChromiumRuntimeInstallation(pin: pin, directory: directory)
    }

    /// Removes every pack except `keep`, plus leftover staging folders and
    /// stale partial downloads. A pack this process runs must be in `keep`:
    /// Chromium cannot unload.
    ///
    /// - Parameter keep: Pack keys to keep.
    public func prune(keeping keep: Set<String>) {
        for name in (try? FileManager.checked.contentsOfDirectory(atPath: root.path)) ?? [] {
            if name.hasPrefix(".staging-") || (!name.hasPrefix(".") && !keep.contains(name)) {
                try? FileManager.checked.removeItem(at: root.appending(path: name))
            }
        }
        let downloads = root.appending(path: ".downloads", directoryHint: .isDirectory)
        for name in (try? FileManager.checked.contentsOfDirectory(atPath: downloads.path)) ?? [] {
            let key = name.replacingOccurrences(of: ".tar.xz.partial", with: "")
            if !keep.contains(key) { try? FileManager.checked.removeItem(at: downloads.appending(path: name)) }
        }
    }

    private func modified(_ installation: ChromiumRuntimeInstallation) -> Date {
        let record = installation.directory.appending(path: ChromiumRuntimeInstallation.recordName)
        return (try? FileManager.default.attributesOfItem(atPath: record.path)[.modificationDate] as? Date) ?? .distantPast
    }
}
