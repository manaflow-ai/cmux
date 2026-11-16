public import Foundation
public import Observation
import Security

/// What Mac Screen keeps on this Mac: the name this Mac registers with the
/// device hub when the person renamed it, and the user's devices' names as
/// last seen (titles of restored tabs before the hub answers). A JSON file,
/// no secrets.
///
/// Link pairing is gone: earlier builds kept paired Macs here and their
/// room secrets (and this Mac's own pairing) in the Keychain under
/// `<bundle id>.mac-screen`. The first load of this build deletes those
/// Keychain items once and drops the old fields from the file.
@Observable
public final class MacScreenStore {
    nonisolated private struct File: Codable, Sendable {
        var hubDeviceName: String?
        var deviceNames: [String: String] = [:]
        var hasSharedBefore = false
        var hasViewedBefore = false
        /// The link-pairing Keychain items were deleted (the one-time cleanup ran).
        var linkPairingsRemoved = false

        init(hubDeviceName: String?, deviceNames: [String: String], hasSharedBefore: Bool, hasViewedBefore: Bool,
             linkPairingsRemoved: Bool) {
            self.hubDeviceName = hubDeviceName
            self.deviceNames = deviceNames
            self.hasSharedBefore = hasSharedBefore
            self.hasViewedBefore = hasViewedBefore
            self.linkPairingsRemoved = linkPairingsRemoved
        }

        enum CodingKeys: String, CodingKey { case hubDeviceName, deviceNames, hasSharedBefore, hasViewedBefore, linkPairingsRemoved }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hubDeviceName = try? c.decodeIfPresent(String.self, forKey: .hubDeviceName)
            deviceNames = (try? c.decodeIfPresent([String: String].self, forKey: .deviceNames)) ?? [:]
            hasSharedBefore = (try? c.decodeIfPresent(Bool.self, forKey: .hasSharedBefore)) ?? false
            hasViewedBefore = (try? c.decodeIfPresent(Bool.self, forKey: .hasViewedBefore)) ?? false
            linkPairingsRemoved = (try? c.decodeIfPresent(Bool.self, forKey: .linkPairingsRemoved)) ?? false
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(hubDeviceName, forKey: .hubDeviceName)
            try c.encode(deviceNames, forKey: .deviceNames)
            try c.encode(hasSharedBefore, forKey: .hasSharedBefore)
            try c.encode(hasViewedBefore, forKey: .hasViewedBefore)
            try c.encode(linkPairingsRemoved, forKey: .linkPairingsRemoved)
        }
    }

    /// The file was read (`load()`); until then it is empty.
    public private(set) var isLoaded = false
    /// This Mac's name in the device hub when the person renamed it (Settings > Devices); nil: the computer name.
    public private(set) var hubDeviceName: String?
    /// The user's devices' names by id, as last seen from the hub (titles of restored device tabs).
    public private(set) var deviceNames: [String: String] = [:]
    /// True after this Mac has successfully been enabled as a screen host once.
    public private(set) var hasSharedBefore = false
    /// True after this Mac has viewed or controlled another Mac once.
    public private(set) var hasViewedBefore = false
    /// The first-use guide is done: this Mac has shared its screen or seen another's.
    public var hasUsedBefore: Bool { hasSharedBefore || hasViewedBefore }
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let file: URL
    /// Deletes every link-pairing Keychain item of this build (tests replace it).
    @ObservationIgnored let removeLinkPairings: @Sendable () -> Void
    @ObservationIgnored private var linkPairingsRemoved = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The file was read, so a save cannot overwrite it with the empty state from before.
    @ObservationIgnored private var fileRead = false
    /// A change came before the file was read; `load()` saves it once the two are merged.
    @ObservationIgnored private var savePending = false

    /// `removeLinkPairings` deletes the Keychain items earlier builds kept for link pairing.
    public init(file: URL, removeLinkPairings: @escaping @Sendable () -> Void = {}) {
        self.file = file
        self.removeLinkPairings = removeLinkPairings
    }

    /// `<Application Support>/<bundle id>/mac-screen.json`; the old link
    /// pairings were Keychain items under `<bundle id>.mac-screen`.
    public static func forApplication(bundleIdentifier: String?) -> MacScreenStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        let bundle = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next"
        let service = "\(bundle).mac-screen"
        return MacScreenStore(file: support.appending(path: bundle).appending(path: "mac-screen.json"), removeLinkPairings: {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        })
    }

    /// Reads the file off the main thread, once; later calls wait for the
    /// first. The first load of this build removes the old link pairings.
    public func load() async {
        if isLoaded { return }
        if loadTask == nil {
            let file = file, remove = removeLinkPairings
            loadTask = Task { [weak self] in
                let stored = await Task.detached { () -> File? in
                    guard let data = try? Data(contentsOf: file) else { return nil }
                    return try? JSONDecoder().decode(File.self, from: data)
                }.value
                guard let self else { return }
                if let stored {
                    hubDeviceName = hubDeviceName ?? stored.hubDeviceName
                    deviceNames = stored.deviceNames.merging(deviceNames) { _, new in new }
                    // A share marked while the file was read stays marked.
                    hasSharedBefore = hasSharedBefore || stored.hasSharedBefore
                    hasViewedBefore = hasViewedBefore || stored.hasViewedBefore
                }
                fileRead = true
                if stored?.linkPairingsRemoved != true {
                    // One time: the Keychain items of link pairing (every saved Mac's room
                    // secret and this Mac's own link) and the file's old fields go.
                    await Task.detached { remove() }.value
                    linkPairingsRemoved = true
                    save()
                } else {
                    linkPairingsRemoved = true
                    if savePending { save() }
                }
                isLoaded = true
            }
        }
        await loadTask?.value
    }

    /// Keeps the name this Mac registers with the device hub (nil: the computer name).
    public func setHubDeviceName(_ name: String?) {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = name?.isEmpty == false ? name : nil
        guard hubDeviceName != value else { return }
        hubDeviceName = value
        save()
    }

    /// Records the first successful Share This Mac flow. This is deliberately a local
    /// hint for the home-page guide; the hub's sharing bit remains authoritative.
    public func markSharedBefore() {
        guard !hasSharedBefore else { return }
        hasSharedBefore = true
        save()
    }

    /// Records the first time this Mac viewed or controlled another Mac (a local hint for the home-page guide).
    public func markViewedBefore() {
        guard !hasViewedBefore else { return }
        hasViewedBefore = true
        save()
    }

    /// Keeps the names the hub lists now (a device's last name stays after it goes away). True when a name changed.
    @discardableResult
    public func rememberDeviceNames(_ names: [String: String]) -> Bool {
        let merged = deviceNames.merging(names.filter { !$0.value.isEmpty }) { _, new in new }
        guard merged != deviceNames else { return false }
        deviceNames = merged
        save()
        return true
    }

    /// Writes the file off the main thread, in order; before the file is read, only notes that a save is due.
    private func save() {
        guard fileRead else { savePending = true; return }
        savePending = false
        let contents = File(hubDeviceName: hubDeviceName, deviceNames: deviceNames, hasSharedBefore: hasSharedBefore,
                            hasViewedBefore: hasViewedBefore, linkPairingsRemoved: linkPairingsRemoved)
        guard let data = try? JSONEncoder().encode(contents) else { return }
        let file = file, previous = saveTask
        saveTask = Task.detached {
            await previous?.value
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Waits for pending writes (tests).
    public func flush() async { await saveTask?.value }
}
