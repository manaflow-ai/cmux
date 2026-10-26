import Foundation

/// The App Group container the app and its notification extensions share
/// (Info.plist `CmuxMobileAppGroup`). Absent in a build signed without the
/// App Group entitlement (the CI App Store profiles and a hand-installed
/// wildcard build): the content extension then shows the generic content and
/// offers "Open in app" only.
///
/// `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` is a
/// synchronous call to containermanagerd. For a group the build is not
/// entitled to it can block long enough for the launch watchdog to kill the
/// app (0x8BADF00D, TestFlight 1.2.0 (20261026194905)). So the group is
/// resolved once, off the main thread, and only when the executable's own
/// signed entitlements name it; every reader awaits `resolved()`.
public struct PushAppGroup: Sendable, Equatable {
    public static let infoKey = "CmuxMobileAppGroup"

    public var identifier: String
    public var directory: URL

    public init(identifier: String, directory: URL) {
        self.identifier = identifier
        self.directory = directory
    }

    /// The running build's resolver.
    public static let resolver = PushAppGroupResolver(environment: .live(bundle: .main))

    /// Starts resolving off the main thread (at launch); returns at once.
    public static func prime() {
        resolver.start()
    }

    /// The running build's group, when it is configured and entitled; nil
    /// otherwise or when the lookup does not answer within `timeout`.
    public static func resolved(timeout: Duration = PushAppGroupResolver.defaultTimeout) async -> PushAppGroup? {
        await resolver.resolved(timeout: timeout)
    }
}

/// Resolves the App Group once per process, on a background queue, and
/// caches the answer (including "none").
public final class PushAppGroupResolver: @unchecked Sendable { // crash-allow: lock-guarded
    /// How long a reader waits for a lookup that has not answered.
    public static let defaultTimeout: Duration = .seconds(2)
    /// For cleanup that must not be skipped (sign-out, sent attachments): it
    /// waits for the real answer, never on the main thread.
    public static let cleanupTimeout: Duration = .seconds(60)

    public struct Environment: Sendable {
        /// Info.plist `CmuxMobileAppGroup`.
        public var configuredIdentifier: @Sendable () -> String?
        /// The App Groups the executable is signed with; nil when they cannot be read.
        public var entitledGroups: @Sendable () -> [String]?
        /// `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`.
        public var containerURL: @Sendable (String) -> URL?

        public init(configuredIdentifier: @escaping @Sendable () -> String?,
                    entitledGroups: @escaping @Sendable () -> [String]?,
                    containerURL: @escaping @Sendable (String) -> URL?) {
            self.configuredIdentifier = configuredIdentifier
            self.entitledGroups = entitledGroups
            self.containerURL = containerURL
        }

        public static func live(bundle: Bundle) -> Environment {
            let identifier = bundle.object(forInfoDictionaryKey: PushAppGroup.infoKey) as? String
            let executable = bundle.executableURL
            return Environment(
                configuredIdentifier: { identifier },
                entitledGroups: { SignedEntitlements.applicationGroups(executable: executable) },
                containerURL: { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
            )
        }
    }

    private let environment: Environment
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var started = false
    private var result: PushAppGroup??
    private var waiters: [UUID: CheckedContinuation<PushAppGroup?, Never>] = [:]

    public init(environment: Environment, queue: DispatchQueue = DispatchQueue(label: "dev.cmux.mobile.app-group", qos: .utility)) {
        self.environment = environment
        self.queue = queue
    }

    /// The answer, once resolved: `.some(nil)` means no group.
    public var cached: PushAppGroup?? {
        lock.withLock { result }
    }

    /// Starts the one lookup on the background queue; returns at once.
    public func start() {
        let first = lock.withLock { () -> Bool in
            defer { started = true }
            return !started
        }
        guard first else { return }
        queue.async { [self] in
            let group = Self.resolve(environment)
            let resumed = lock.withLock { () -> [CheckedContinuation<PushAppGroup?, Never>] in
                result = .some(group)
                defer { waiters.removeAll() }
                return Array(waiters.values)
            }
            for waiter in resumed { waiter.resume(returning: group) }
        }
    }

    /// The group, waiting at most `timeout` for the lookup (nil after it).
    public func resolved(timeout: Duration = PushAppGroupResolver.defaultTimeout) async -> PushAppGroup? {
        start()
        if let result = cached { return result }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let waiting = lock.withLock { () -> Bool in
                if result != nil { return false }
                waiters[id] = continuation
                return true
            }
            guard waiting else {
                continuation.resume(returning: cached ?? nil)
                return
            }
            // A bounded wait for a lookup that may never answer, not synchronization.
            let (seconds, attoseconds) = timeout.components
            let nanos = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .nanoseconds(nanos)) { [self] in
                let timedOut = lock.withLock { waiters.removeValue(forKey: id) }
                timedOut?.resume(returning: nil)
            }
        }
    }

    /// Never on the main thread: the container lookup is a synchronous XPC.
    static func resolve(_ environment: Environment) -> PushAppGroup? {
        guard let id = environment.configuredIdentifier(), !id.isEmpty, !id.hasPrefix("$(") else { return nil }
        // Signed without this group (the CI App Store profiles): no lookup at all.
        if let groups = environment.entitledGroups(), !groups.contains(id) { return nil }
        guard let url = environment.containerURL(id) else { return nil }
        return PushAppGroup(identifier: id, directory: url)
    }
}

/// The entitlements the running executable is signed with, read from its own
/// Mach-O: the `__TEXT,__entitlements` section (simulator builds) or the
/// entitlements blob of its code signature (device builds). No private API.
public struct SignedEntitlements: Sendable {
    public static let applicationGroupsKey = "com.apple.security.application-groups"

    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// The App Groups `executable` is signed with: empty when it is signed
    /// without any, nil when its entitlements cannot be read.
    public static func applicationGroups(executable: URL?) -> [String]? {
        executable.flatMap { SignedEntitlements(executable: $0).applicationGroups() }
    }

    /// The App Groups: empty when signed without any, nil when unreadable.
    public func applicationGroups() -> [String]? {
        guard let entitlements = read() else { return nil }
        return entitlements[Self.applicationGroupsKey] as? [String] ?? []
    }

    /// The executable's entitlements; nil when it has none that can be read.
    public func read() -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: executable) else { return nil }
        defer { try? handle.close() }
        guard let xml = Self.entitlementsXML(MachOFile(handle: handle)) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: xml, format: nil)) as? [String: Any]
    }

    static let segmentCommand64: UInt32 = 0x19
    static let codeSignatureCommand: UInt32 = 0x1d
    static let entitlementsSlot: UInt32 = 5
    static let superBlobMagic: UInt32 = 0xfade_0cc0
    static let entitlementsBlobMagic: UInt32 = 0xfade_7171
    static let maxBlob = 1 << 20

    static func entitlementsXML(_ file: MachOFile) -> Data? {
        guard let slice = file.sliceOffset() else { return nil }
        guard let header = file.read(at: slice, count: 32), header.u32le(0) == 0xfeed_facf else { return nil }
        let commands = Int(header.u32le(16))
        let size = Int(header.u32le(20))
        guard size > 0, size < 16 << 20, let loads = file.read(at: slice + 32, count: size) else { return nil }
        var section: Data?
        var signature: Data?
        var at = 0
        for _ in 0..<commands {
            guard at + 8 <= loads.count else { break }
            let cmd = loads.u32le(at)
            let cmdSize = Int(loads.u32le(at + 4))
            guard cmdSize >= 8, at + cmdSize <= loads.count else { break }
            if cmd == segmentCommand64, cmdSize >= 72, loads.name(at + 8) == "__TEXT" {
                let sections = Int(loads.u32le(at + 64))
                for index in 0..<sections {
                    let s = at + 72 + index * 80
                    guard s + 80 <= at + cmdSize, loads.name(s) == "__entitlements" else { continue }
                    let length = Int(loads.u64le(s + 40))
                    let offset = Int(loads.u32le(s + 48))
                    if length > 0, length < maxBlob { section = file.read(at: slice + offset, count: length) }
                }
            } else if cmd == codeSignatureCommand, cmdSize >= 16 {
                let offset = Int(loads.u32le(at + 8))
                let length = Int(loads.u32le(at + 12))
                if length > 12, length < 64 << 20 { signature = file.read(at: slice + offset, count: length) }
            }
            at += cmdSize
        }
        if let section, !section.isEmpty { return section }
        return signature.flatMap(entitlementsBlob)
    }

    /// The entitlements blob (XML) of a code signature super blob.
    static func entitlementsBlob(_ signature: Data) -> Data? {
        guard signature.count >= 12, signature.u32be(0) == superBlobMagic else { return nil }
        let count = Int(signature.u32be(8))
        for index in 0..<count {
            let entry = 12 + index * 8
            guard entry + 8 <= signature.count else { return nil }
            guard signature.u32be(entry) == entitlementsSlot else { continue }
            let offset = Int(signature.u32be(entry + 4))
            guard offset + 8 <= signature.count, signature.u32be(offset) == entitlementsBlobMagic else { return nil }
            let length = Int(signature.u32be(offset + 4))
            guard length >= 8, offset + length <= signature.count else { return nil }
            return signature.subdata(in: (signature.startIndex + offset + 8)..<(signature.startIndex + offset + length))
        }
        return nil
    }
}

/// Bounded reads of a Mach-O file (thin, or the slice of a fat one for this CPU).
struct MachOFile {
    let handle: FileHandle

    func read(at offset: Int, count: Int) -> Data? {
        guard offset >= 0, count > 0 else { return nil }
        do {
            try handle.seek(toOffset: UInt64(offset))
            guard let data = try handle.read(upToCount: count), data.count == count else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// Where the 64-bit image for this CPU starts.
    func sliceOffset() -> Int? {
        guard let magic = read(at: 0, count: 8) else { return nil }
        if magic.u32le(0) == 0xfeed_facf { return 0 }
        guard magic.u32be(0) == 0xcafe_babe else { return nil }
        let count = Int(magic.u32be(4))
        #if arch(arm64)
        let cpu: UInt32 = 0x0100_000c
        #else
        let cpu: UInt32 = 0x0100_0007
        #endif
        guard count > 0, count < 32, let archs = read(at: 8, count: count * 20) else { return nil }
        for index in 0..<count where archs.u32be(index * 20) == cpu {
            return Int(archs.u32be(index * 20 + 8))
        }
        return nil
    }
}

extension Data {
    func u32le(_ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= count else { return 0 }
        return self[(startIndex + at)..<(startIndex + at + 4)].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    func u32be(_ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= count else { return 0 }
        return self[(startIndex + at)..<(startIndex + at + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    func u64le(_ at: Int) -> UInt64 {
        guard at >= 0, at + 8 <= count else { return 0 }
        return self[(startIndex + at)..<(startIndex + at + 8)].reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// A NUL-padded 16-byte Mach-O name.
    func name(_ at: Int) -> String {
        guard at >= 0, at + 16 <= count else { return "" }
        let bytes = self[(startIndex + at)..<(startIndex + at + 16)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}
