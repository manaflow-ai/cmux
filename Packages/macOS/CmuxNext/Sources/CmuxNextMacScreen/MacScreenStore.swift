public import CmuxScreenKit
public import Foundation
public import Observation
import Security

/// One Mac this Mac can show: its name and view choices. The pairing
/// (signaling Worker, room and secret) is in the Keychain, never here.
public nonisolated struct SavedMac: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var addedAt: Date
    public var lastConnectedAt: Date?
    public var preferences: ScreenPreferences

    public init(id: UUID = UUID(), name: String, addedAt: Date = Date(), lastConnectedAt: Date? = nil,
                preferences: ScreenPreferences = ScreenPreferences()) {
        self.id = id
        self.name = name
        self.addedAt = addedAt
        self.lastConnectedAt = lastConnectedAt
        self.preferences = preferences
    }
}

/// A secret read: found, not there, or the store refused (locked, access denied).
public enum MacScreenSecretRead: Equatable {
    case found(VNCPairing)
    case missing
    case failed(Int32)
}

/// Where pairing secrets live. The app uses the login Keychain; tests use memory.
public protocol MacScreenSecrets: AnyObject {
    func read(_ account: String) -> MacScreenSecretRead
    /// False when the store refused the write (a locked Keychain, or a process it denies).
    @discardableResult
    func save(_ pairing: VNCPairing, for account: String) -> Bool
    func remove(_ account: String)
}

extension MacScreenSecrets {
    /// The pairing, or nil when it is missing or unreadable.
    public func pairing(for account: String) -> VNCPairing? {
        if case let .found(pairing) = read(account) { return pairing }
        return nil
    }
}

/// Generic passwords under one service (the app's bundle id, so tagged
/// builds keep their own), one per saved Mac plus `host` for Share This Mac.
public final class KeychainMacScreenSecrets: MacScreenSecrets {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func read(_ account: String) -> MacScreenSecretRead {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = result as? Data else { return .failed(status) }
        guard let pairing = try? JSONDecoder().decode(VNCPairing.self, from: data) else { return .missing }
        return .found(pairing)
    }

    @discardableResult
    public func save(_ pairing: VNCPairing, for account: String) -> Bool {
        guard let data = try? JSONEncoder().encode(pairing) else { return false }
        let query = baseQuery(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public func remove(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

/// Secrets in memory, for tests and previews.
public final class MemoryMacScreenSecrets: MacScreenSecrets {
    private var items: [String: VNCPairing] = [:]
    /// Accounts whose reads fail (a locked or denied Keychain), for tests.
    public var failing: Set<String> = []
    /// Every write is refused (a Keychain the process cannot write, e.g. a launch from ssh), for tests.
    public var writesFail = false
    public init() {}
    public func read(_ account: String) -> MacScreenSecretRead {
        if failing.contains(account) { return .failed(-25308) }
        return items[account].map(MacScreenSecretRead.found) ?? .missing
    }
    @discardableResult
    public func save(_ pairing: VNCPairing, for account: String) -> Bool {
        if writesFail { return false }
        items[account] = pairing
        return true
    }
    public func remove(_ account: String) { items[account] = nil }
}

/// The Macs this Mac has paired with, and whether it shares its own screen.
/// The list and the share switch are a JSON file (no secrets); pairings are
/// `MacScreenSecrets`.
@Observable
public final class MacScreenStore {
    public enum AddError: Error, Equatable {
        /// Not a `cmux-vnc://pair` link.
        case notALink
        /// A pairing for RFB over WebRTC; this app shows screen streams only.
        case notAScreenStream
        /// This Mac's own Share This Mac link.
        case ownLink
        /// The Keychain refused the pairing's secret, so the Mac is not saved.
        case secretNotSaved
    }

    nonisolated private struct File: Codable, Sendable {
        var macs: [SavedMac] = []
        var shareEnabled = false
        /// The name this Mac registers with the device hub when the person renamed it.
        var hubDeviceName: String?
        /// The user's devices' names by id, as last seen: restored device tabs are titled before the hub answers.
        var deviceNames: [String: String] = [:]

        init(macs: [SavedMac] = [], shareEnabled: Bool = false, hubDeviceName: String? = nil, deviceNames: [String: String] = [:]) {
            self.macs = macs
            self.shareEnabled = shareEnabled
            self.hubDeviceName = hubDeviceName
            self.deviceNames = deviceNames
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            macs = try c.decodeIfPresent([SavedMac].self, forKey: .macs) ?? []
            shareEnabled = try c.decodeIfPresent(Bool.self, forKey: .shareEnabled) ?? false
            hubDeviceName = try c.decodeIfPresent(String.self, forKey: .hubDeviceName)
            deviceNames = (try? c.decodeIfPresent([String: String].self, forKey: .deviceNames)) ?? [:]
        }
    }

    public private(set) var macs: [SavedMac] = []
    /// The list was read from disk (`load()`); until then it is empty.
    public private(set) var isLoaded = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Share This Mac is on (the person turned it on and has not turned it off).
    public private(set) var shareEnabled = false
    /// This Mac's name in the device hub when the person renamed it (Settings > Devices); nil: the computer name.
    public private(set) var hubDeviceName: String?
    /// The user's devices' names by id, as last seen from the hub (titles of restored device tabs).
    public private(set) var deviceNames: [String: String] = [:]
    @ObservationIgnored private let file: URL
    @ObservationIgnored public let secrets: any MacScreenSecrets
    /// A saved Mac was renamed (open tabs take the new name).
    @ObservationIgnored public var onRenamed: ((UUID, String) -> Void)?
    /// A saved Mac was forgotten (its open tabs end their sessions).
    @ObservationIgnored public var onForgotten: ((UUID) -> Void)?

    public init(file: URL, secrets: any MacScreenSecrets) {
        self.file = file
        self.secrets = secrets
    }

    /// Reads the list off the main thread, once; later calls wait for the first.
    public func load() async {
        if isLoaded { return }
        if loadTask == nil {
            let file = file
            loadTask = Task { [weak self] in
                let stored = await Task.detached { () -> File? in
                    guard let data = try? Data(contentsOf: file) else { return nil }
                    return try? JSONDecoder().decode(File.self, from: data)
                }.value
                guard let self else { return }
                if let stored {
                    // Anything added before the read finished stays.
                    macs = stored.macs + macs.filter { mac in !stored.macs.contains { $0.id == mac.id } }
                    shareEnabled = shareEnabled || stored.shareEnabled
                    hubDeviceName = hubDeviceName ?? stored.hubDeviceName
                    deviceNames = stored.deviceNames.merging(deviceNames) { _, new in new }
                }
                isLoaded = true
            }
        }
        await loadTask?.value
    }

    /// `<Application Support>/<bundle id>/mac-screen.json` and the login
    /// Keychain under the bundle id.
    public static func forApplication(bundleIdentifier: String?) -> MacScreenStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        let bundle = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next"
        return MacScreenStore(file: support.appending(path: bundle).appending(path: "mac-screen.json"),
                              secrets: KeychainMacScreenSecrets(service: "\(bundle).mac-screen"))
    }

    public func mac(_ id: UUID?) -> SavedMac? {
        guard let id else { return nil }
        return macs.first { $0.id == id }
    }

    public func pairing(for id: UUID) -> VNCPairing? {
        secrets.pairing(for: id.uuidString)
    }

    /// Saves the Mac a pairing link names. Pairing the same room again
    /// (a renamed host, a new secret) updates that Mac instead of adding one.
    @discardableResult
    public func add(link text: String) -> Result<SavedMac, AddError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let pairing = VNCPairing(link: url) else { return .failure(.notALink) }
        guard pairing.isStream else { return .failure(.notAScreenStream) }
        if let own = secrets.pairing(for: Self.hostAccount), own.room == pairing.room { return .failure(.ownLink) }
        if let index = macs.firstIndex(where: { secrets.pairing(for: $0.id.uuidString)?.room == pairing.room }) {
            guard secrets.save(pairing, for: macs[index].id.uuidString) else { return .failure(.secretNotSaved) }
            macs[index].name = pairing.name
            save()
            return .success(macs[index])
        }
        let mac = SavedMac(name: pairing.name)
        guard secrets.save(pairing, for: mac.id.uuidString) else { return .failure(.secretNotSaved) }
        macs.append(mac)
        save()
        return .success(mac)
    }

    public func forget(_ id: UUID) {
        macs.removeAll { $0.id == id }
        secrets.remove(id.uuidString)
        save()
        onForgotten?(id)
    }

    public func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = macs.firstIndex(where: { $0.id == id }) else { return }
        macs[index].name = name
        save()
        onRenamed?(id, name)
    }

    /// Keeps a session's view choices and when it last connected.
    public func connected(_ id: UUID, preferences: ScreenPreferences) {
        guard let index = macs.firstIndex(where: { $0.id == id }) else { return }
        macs[index].preferences = preferences
        macs[index].lastConnectedAt = Date()
        save()
    }

    public func update(_ id: UUID, preferences: ScreenPreferences) {
        guard let index = macs.firstIndex(where: { $0.id == id }), macs[index].preferences != preferences else { return }
        macs[index].preferences = preferences
        save()
    }

    // MARK: Share This Mac

    static let hostAccount = "host"

    /// Keeps the name this Mac registers with the device hub (nil: the computer name).
    public func setHubDeviceName(_ name: String?) {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = name?.isEmpty == false ? name : nil
        guard hubDeviceName != value else { return }
        hubDeviceName = value
        save()
    }

    /// Keeps the names the hub lists now (a device's last name stays after it goes away).
    public func rememberDeviceNames(_ names: [String: String]) {
        let merged = deviceNames.merging(names.filter { !$0.value.isEmpty }) { _, new in new }
        guard merged != deviceNames else { return }
        deviceNames = merged
        save()
    }

    public func setShareEnabled(_ enabled: Bool) {
        guard shareEnabled != enabled else { return }
        shareEnabled = enabled
        save()
    }

    /// This Mac's own pairing: kept across launches, so paired Macs stay
    /// paired. A new one only when there is none; nil when the Keychain
    /// cannot be read (resetting then would unpair every device).
    public func hostPairing(name: String) -> VNCPairing? {
        switch secrets.read(Self.hostAccount) {
        case var .found(saved) where saved.isStream:
            if saved.name != name {
                saved.name = name
                secrets.save(saved, for: Self.hostAccount)
            }
            return saved
        case .found, .missing:
            return resetHostPairing(name: name)
        case .failed:
            return nil
        }
    }

    /// A new room and secret: every Mac paired with the old link loses access.
    /// Nil when the Keychain refused it (a link it does not keep would change
    /// on every launch); the old link, if any, stays.
    @discardableResult
    public func resetHostPairing(name: String) -> VNCPairing? {
        let pairing = VNCPairing.generate(name: name, kind: "stream")
        return secrets.save(pairing, for: Self.hostAccount) ? pairing : nil
    }

    /// Writes the list off the main thread, in order.
    private func save() {
        guard let data = try? JSONEncoder().encode(File(macs: macs, shareEnabled: shareEnabled, hubDeviceName: hubDeviceName,
                                                             deviceNames: deviceNames)) else { return }
        let file = file, previous = saveTask
        saveTask = Task.detached {
            await previous?.value
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Waits for pending writes (tests).
    public func flush() async { await saveTask?.value }
}
