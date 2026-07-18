import Darwin
import CMUXAgentLaunch
import CmuxControlSocket
import Dispatch
import Foundation
import OSLog
import SQLite3

nonisolated private let agentHookDeliveryLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "AgentHookDelivery"
)

private final class AgentHookEphemeralEnvironmentStore: @unchecked Sendable {
    private static let maximumEntries = 4_096
    private static let maximumBytes = 16 * 1024 * 1024

    // Socket admission is synchronous and delivery runs on the queue actor;
    // this short lock is the boundary protecting the memory-only credential cache.
    private let lock = NSLock()
    private var environments: [String: [String: String]] = [:]
    private var environmentBytes: [String: Int] = [:]
    private var totalBytes = 0

    func replace(_ environment: [String: String], for deliveryID: String) -> Bool {
        let byteCount = environment.reduce(into: 0) { total, entry in
            total += entry.key.utf8.count + entry.value.utf8.count + 2
        }
        lock.lock()
        defer { lock.unlock() }
        let priorBytes = environmentBytes[deliveryID] ?? 0
        if environment.isEmpty {
            environments.removeValue(forKey: deliveryID)
            environmentBytes.removeValue(forKey: deliveryID)
            totalBytes -= priorBytes
            return true
        }
        let isNewEntry = environments[deliveryID] == nil
        guard (!isNewEntry || environments.count < Self.maximumEntries),
              byteCount <= Self.maximumBytes,
              totalBytes - priorBytes <= Self.maximumBytes - byteCount else {
            return false
        }
        environments[deliveryID] = environment
        environmentBytes[deliveryID] = byteCount
        totalBytes = totalBytes - priorBytes + byteCount
        return true
    }

    func environment(for deliveryID: String) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return environments[deliveryID] ?? [:]
    }

    func remove(deliveryID: String) {
        lock.lock()
        defer { lock.unlock() }
        if let removedBytes = environmentBytes.removeValue(forKey: deliveryID) {
            totalBytes -= removedBytes
        }
        environments.removeValue(forKey: deliveryID)
    }
}

/// Imports capability-authenticated native hook records from a private,
/// per-bundle shared-memory outbox. Directory notifications are hints only:
/// startup and periodic reconciliation make process-crash recovery complete.
actor AgentHookOutbox {
    static let environmentKey = "CMUX_AGENT_HOOK_OUTBOX_DIR"
    static let capabilityEnvironmentKey = "CMUX_AGENT_HOOK_OUTBOX_CAPABILITY"

    private static let maximumMarkerBytes = 512
    private static let maximumMessageBytes = 12 * 1024 * 1024
    private static let readyMarkerPrefix = "ready-"
    private static let pendingMarkerPrefix = "pending-"
    private static let capabilitySecretName = ".capability-secret-v1"
    private static let budgetFileName = ".quota-v1"
    private static let budgetMagic = Array("CMUXHQ01".utf8)
    private static let budgetVersion: UInt32 = 1
    private static let budgetHeaderBytes = 64
    private static let budgetRecordBytes = 32
    private static let maximumBudgetRecords = 1_024
    private static let maximumBudgetBytes: UInt64 = 256 * 1024 * 1024
    private static let budgetStateReserved: UInt32 = 1
    private static let budgetStatePublished: UInt32 = 2

    private struct BudgetRecord: Sendable, Equatable {
        let token: UInt64
        let reservedBytes: UInt64
        let createdNanoseconds: UInt64
        let ownerPID: Int32
        let state: UInt32
    }

    private struct BudgetLedger: Sendable {
        let slotCount: Int
        let maximumBytes: UInt64
        var records: [BudgetRecord?]
    }

    private struct Marker: Sendable {
        let sharedMemoryName: String
        let nonce: String
        let code: Data
        let byteCount: Int
        let reservationToken: UInt64
    }

    private enum MarkerReadResult: Sendable {
        case valid(Marker)
        case malformed(sharedMemoryName: String?)
        case missing
        case retryable
    }

    private enum FileReadResult: Sendable {
        case data(Data)
        case malformed
        case retryable
    }

    private enum SharedMemoryReadResult: Sendable {
        case data(Data)
        case invalid
        case retryable
    }

    private enum ImportRecordResult: Sendable, Equatable {
        case advanced
        case blocked
    }

    private enum PendingMarkerState: Sendable {
        case stale
        case fresh(remainingGrace: TimeInterval)
        case missing
        case retryable
    }

    private struct MarkerCandidate: Sendable {
        let name: String
        let publicationKey: String
        let isPending: Bool
    }

    private struct MarkerScan: Sendable {
        var candidates: [MarkerCandidate] = []
        var freshPendingBarrier: String?
        var nextPendingDelay: TimeInterval?
    }

    nonisolated let directoryURL: URL
    nonisolated let capabilitySecretURL: URL
    private let directoryDescriptor: Int32
    private let budgetDescriptor: Int32
    private nonisolated let capabilityAuthority: SocketClientCapabilityAuthority
    private let deliveryQueue: AgentHookDeliveryQueue
    private let reconciliationInterval: TimeInterval
    private let pendingRecoveryGrace: TimeInterval
    private let sharedMemoryReadErrorForTesting: (@Sendable () -> Int32?)?

    private var watcher: DispatchSourceFileSystemObject?
    private var reconciliationTask: Task<Void, Never>?
    private var pendingRecoveryTask: Task<Void, Never>?
    private var started = false

    private init(
        directoryURL: URL,
        capabilitySecretURL: URL,
        directoryDescriptor: Int32,
        budgetDescriptor: Int32,
        capabilityAuthority: SocketClientCapabilityAuthority,
        deliveryQueue: AgentHookDeliveryQueue,
        reconciliationInterval: TimeInterval,
        pendingRecoveryGrace: TimeInterval,
        sharedMemoryReadErrorForTesting: (@Sendable () -> Int32?)?
    ) {
        self.directoryURL = directoryURL
        self.capabilitySecretURL = capabilitySecretURL
        self.directoryDescriptor = directoryDescriptor
        self.budgetDescriptor = budgetDescriptor
        self.capabilityAuthority = capabilityAuthority
        self.deliveryQueue = deliveryQueue
        self.reconciliationInterval = max(0.05, reconciliationInterval)
        self.pendingRecoveryGrace = max(0, pendingRecoveryGrace)
        self.sharedMemoryReadErrorForTesting = sharedMemoryReadErrorForTesting
    }

    deinit {
        reconciliationTask?.cancel()
        pendingRecoveryTask?.cancel()
        watcher?.cancel()
        Darwin.close(budgetDescriptor)
        Darwin.close(directoryDescriptor)
    }

    nonisolated static func defaultDirectoryURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
    ) -> URL {
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("agent-hook-outbox", isDirectory: true)
    }

    /// Creates and validates the directory before its path is exported to any
    /// terminal. A failed preparation leaves the socket admission path active.
    nonisolated static func prepare(
        directoryURL: URL = defaultDirectoryURL(),
        audience: String = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
        deliveryQueue: AgentHookDeliveryQueue,
        reconciliationInterval: TimeInterval = 30,
        pendingRecoveryGrace: TimeInterval = 2,
        sharedMemoryReadErrorForTesting: (@Sendable () -> Int32?)? = nil
    ) -> AgentHookOutbox? {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directoryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            agentHookDeliveryLogger.error(
                "Could not prepare hook outbox parent: \(error.localizedDescription, privacy: .private)"
            )
            return nil
        }

        if Darwin.mkdir(directoryURL.path, 0o700) != 0, errno != EEXIST {
            agentHookDeliveryLogger.error("Could not create hook outbox directory: errno=\(errno)")
            return nil
        }
        var pathStatus = stat()
        guard Darwin.lstat(directoryURL.path, &pathStatus) == 0,
              (pathStatus.st_mode & S_IFMT) == S_IFDIR,
              pathStatus.st_uid == geteuid(),
              Darwin.chmod(directoryURL.path, 0o700) == 0 else {
            agentHookDeliveryLogger.error("Hook outbox directory failed ownership validation")
            return nil
        }

        let descriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            agentHookDeliveryLogger.error("Could not open hook outbox directory: errno=\(errno)")
            return nil
        }
        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              (descriptorStatus.st_mode & S_IFMT) == S_IFDIR,
              descriptorStatus.st_uid == geteuid(),
              (descriptorStatus.st_mode & 0o777) == 0o700 else {
            Darwin.close(descriptor)
            agentHookDeliveryLogger.error("Opened hook outbox directory is not private")
            return nil
        }

        guard let secret = loadOrCreateCapabilitySecret(
            directoryDescriptor: descriptor
        ) else {
            Darwin.close(descriptor)
            agentHookDeliveryLogger.error("Could not load private hook outbox credential")
            return nil
        }
        guard let budgetDescriptor = prepareBudget(
            directoryDescriptor: descriptor
        ) else {
            Darwin.close(descriptor)
            agentHookDeliveryLogger.error("Could not prepare bounded hook outbox quota")
            return nil
        }
        sweepStaleCapabilityTemporaryFiles(directoryDescriptor: descriptor)
        let normalizedAudience = audience.trimmingCharacters(in: .whitespacesAndNewlines)
        let capabilityAuthority = SocketClientCapabilityAuthority(
            secret: secret,
            audience: normalizedAudience.isEmpty ? "com.cmuxterm.app" : normalizedAudience
        )

        return AgentHookOutbox(
            directoryURL: directoryURL,
            capabilitySecretURL: directoryURL.appendingPathComponent(
                capabilitySecretName,
                isDirectory: false
            ),
            directoryDescriptor: descriptor,
            budgetDescriptor: budgetDescriptor,
            capabilityAuthority: capabilityAuthority,
            deliveryQueue: deliveryQueue,
            reconciliationInterval: reconciliationInterval,
            pendingRecoveryGrace: pendingRecoveryGrace,
            sharedMemoryReadErrorForTesting: sharedMemoryReadErrorForTesting
        )
    }

    /// Each terminal gets a distinct bearer token. Only its public nonce and
    /// a message-specific authenticator are written to the marker.
    nonisolated func issueCapability() -> String {
        capabilityAuthority.issueCapability()
    }

    /// Installs the master secret with a no-replace hard link. Concurrent app
    /// processes either install one complete file or read the winner; the
    /// canonical path is never visible with partial contents.
    private nonisolated static func loadOrCreateCapabilitySecret(
        directoryDescriptor: Int32
    ) -> Data? {
        var status = stat()
        if fstatat(
            directoryDescriptor,
            capabilitySecretName,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            return readCapabilitySecret(directoryDescriptor: directoryDescriptor)
        }
        guard errno == ENOENT else { return nil }

        var generator = SystemRandomNumberGenerator()
        let secret = Data((0..<SocketClientCapabilityAuthority.secureByteCount).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
        let random = UInt64.random(in: .min ... .max, using: &generator)
        let temporaryName = String(
            format: ".capability-secret-v1.tmp-%d-%016llx",
            getpid(),
            random
        )
        let temporaryDescriptor = openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard temporaryDescriptor >= 0 else { return nil }
        var keepTemporaryFile = true
        defer {
            Darwin.close(temporaryDescriptor)
            if keepTemporaryFile {
                _ = unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        var temporaryStatus = stat()
        guard fchmod(temporaryDescriptor, 0o600) == 0,
              fstat(temporaryDescriptor, &temporaryStatus) == 0,
              (temporaryStatus.st_mode & S_IFMT) == S_IFREG,
              temporaryStatus.st_uid == geteuid(),
              (temporaryStatus.st_mode & 0o777) == 0o600,
              writeRegularFile(descriptor: temporaryDescriptor, data: secret),
              fsync(temporaryDescriptor) == 0 else {
            return nil
        }

        let linkStatus = linkat(
            directoryDescriptor,
            temporaryName,
            directoryDescriptor,
            capabilitySecretName,
            0
        )
        let linkError = errno
        _ = unlinkat(directoryDescriptor, temporaryName, 0)
        keepTemporaryFile = false
        guard linkStatus == 0 || linkError == EEXIST else { return nil }
        if linkStatus == 0, fsync(directoryDescriptor) != 0 {
            return nil
        }
        return readCapabilitySecret(directoryDescriptor: directoryDescriptor)
    }

    private nonisolated static func readCapabilitySecret(
        directoryDescriptor: Int32
    ) -> Data? {
        let descriptor = openat(
            directoryDescriptor,
            capabilitySecretName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              (status.st_mode & 0o777) == 0o600,
              status.st_size == off_t(SocketClientCapabilityAuthority.secureByteCount) else {
            return nil
        }
        guard case .data(let secret) = readRegularFile(
            descriptor: descriptor,
            count: SocketClientCapabilityAuthority.secureByteCount
        ) else { return nil }
        return secret
    }

    private nonisolated static func sweepStaleCapabilityTemporaryFiles(
        directoryDescriptor: Int32
    ) {
        let scanDescriptor = openat(
            directoryDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard scanDescriptor >= 0, let directory = fdopendir(scanDescriptor) else {
            if scanDescriptor >= 0 { Darwin.close(scanDescriptor) }
            return
        }
        defer { closedir(directory) }

        let prefix = ".capability-secret-v1.tmp-"
        let now = Date().timeIntervalSince1970
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) {
                    String(cString: $0)
                }
            }
            guard name.hasPrefix(prefix) else { continue }
            let components = name.dropFirst(prefix.count).split(
                separator: "-",
                omittingEmptySubsequences: false
            )
            guard components.count == 2,
                  !components[0].isEmpty,
                  components[0].count <= 10,
                  components[0].allSatisfy(\.isNumber),
                  components[1].count == 16,
                  components[1].allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                continue
            }
            var status = stat()
            guard fstatat(
                directoryDescriptor,
                name,
                &status,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_uid == geteuid(),
                  (status.st_mode & 0o777) == 0o600,
                  status.st_size == off_t(SocketClientCapabilityAuthority.secureByteCount) else {
                continue
            }
            let modifiedAt = TimeInterval(status.st_mtimespec.tv_sec)
                + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
            guard now - modifiedAt >= 60 else { continue }
            _ = unlinkat(directoryDescriptor, name, 0)
        }
    }

    private nonisolated static func isRetryableIOError(_ code: Int32) -> Bool {
        code == EINTR
            || code == EAGAIN
            || code == EBUSY
            || code == EIO
            || code == EMFILE
            || code == ENFILE
            || code == ENOMEM
            || code == ENOBUFS
            || code == ETIMEDOUT
            || code == ESTALE
    }

    private nonisolated static func writeRegularFile(
        descriptor: Int32,
        data: Data
    ) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < data.count {
                let amount = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
                if amount > 0 {
                    offset += amount
                } else if amount < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// Rebuilds the fixed reservation ledger from discoverable markers while
    /// holding the same cross-process lock used by native publishers. A corrupt
    /// ledger therefore fails closed in helpers until the app can recompute it.
    private nonisolated static func prepareBudget(
        directoryDescriptor: Int32
    ) -> Int32? {
        let descriptor = openat(
            directoryDescriptor,
            budgetFileName,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else { return nil }
        var keepDescriptor = false
        defer {
            if !keepDescriptor { Darwin.close(descriptor) }
        }
        var status = stat()
        guard fchmod(descriptor, 0o600) == 0,
              fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              (status.st_mode & 0o777) == 0o600,
              lockBudget(descriptor) else {
            return nil
        }
        defer { unlockBudget(descriptor) }

        guard let markerReservations = budgetMarkerReservations(
            directoryDescriptor: directoryDescriptor
        ) else { return nil }
        let existingLedger = readBudgetLedger(descriptor: descriptor)
        let existingByToken = Dictionary(
            uniqueKeysWithValues: (existingLedger?.records.compactMap { $0 } ?? []).map {
                ($0.token, $0)
            }
        )
        var retained: [BudgetRecord] = []
        retained.reserveCapacity(markerReservations.count + 8)
        var retainedTokens: Set<UInt64> = []
        var totalBytes: UInt64 = 0

        for (token, reservedBytes) in markerReservations.sorted(by: { $0.key < $1.key }) {
            let existing = existingByToken[token]
            let record = BudgetRecord(
                token: token,
                reservedBytes: reservedBytes,
                createdNanoseconds: existing?.createdNanoseconds ?? 0,
                ownerPID: existing?.ownerPID ?? 0,
                state: budgetStatePublished
            )
            guard totalBytes <= maximumBudgetBytes - reservedBytes else { return nil }
            totalBytes += reservedBytes
            retained.append(record)
            retainedTokens.insert(token)
        }

        if let existingLedger {
            for record in existingLedger.records.compactMap({ $0 })
                where !retainedTokens.contains(record.token) {
                if processExists(record.ownerPID) {
                    guard retained.count < maximumBudgetRecords,
                          totalBytes <= maximumBudgetBytes - record.reservedBytes else {
                        return nil
                    }
                    retained.append(record)
                    retainedTokens.insert(record.token)
                    totalBytes += record.reservedBytes
                } else {
                    unlinkSharedMemory(token: record.token)
                }
            }
        }
        guard retained.count <= maximumBudgetRecords else { return nil }
        guard persistBudgetRecords(
            retained,
            existingLedger: existingLedger,
            descriptor: descriptor
        ) else { return nil }
        keepDescriptor = true
        return descriptor
    }

    private nonisolated static func budgetMarkerReservations(
        directoryDescriptor: Int32
    ) -> [UInt64: UInt64]? {
        let scanDescriptor = openat(
            directoryDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard scanDescriptor >= 0, let directory = fdopendir(scanDescriptor) else {
            if scanDescriptor >= 0 { Darwin.close(scanDescriptor) }
            return nil
        }
        defer { closedir(directory) }
        var reservations: [UInt64: UInt64] = [:]
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) {
                    String(cString: $0)
                }
            }
            guard publicationKey(markerName: name, prefix: readyMarkerPrefix) != nil
                    || publicationKey(markerName: name, prefix: pendingMarkerPrefix) != nil else {
                continue
            }
            let markerDescriptor = openat(
                directoryDescriptor,
                name,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard markerDescriptor >= 0 else {
                if errno == ENOENT { continue }
                return nil
            }
            var markerStatus = stat()
            guard fstat(markerDescriptor, &markerStatus) == 0,
                  markerStatus.st_size > 0,
                  markerStatus.st_size <= off_t(maximumMarkerBytes) else {
                Darwin.close(markerDescriptor)
                _ = unlinkat(directoryDescriptor, name, 0)
                continue
            }
            let markerData: Data
            switch readRegularFile(descriptor: markerDescriptor, count: Int(markerStatus.st_size)) {
            case .data(let data): markerData = data
            case .retryable:
                Darwin.close(markerDescriptor)
                return nil
            case .malformed:
                Darwin.close(markerDescriptor)
                _ = unlinkat(directoryDescriptor, name, 0)
                continue
            }
            Darwin.close(markerDescriptor)
            guard let parsed = budgetReservation(
                markerData: markerData,
                markerName: name
            ) else {
                if let sharedMemoryName = recoverSharedMemoryName(markerData) {
                    _ = shm_unlink(sharedMemoryName)
                }
                _ = unlinkat(directoryDescriptor, name, 0)
                continue
            }
            if let existing = reservations[parsed.token], existing != parsed.reservedBytes {
                return nil
            }
            reservations[parsed.token] = parsed.reservedBytes
        }
        return reservations
    }

    private nonisolated static func budgetReservation(
        markerData: Data,
        markerName: String
    ) -> (token: UInt64, reservedBytes: UInt64)? {
        guard let text = String(data: markerData, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard (lines.count == 5 || lines.count == 6), lines.last?.isEmpty == true,
              isSharedMemoryName(String(lines[0])),
              let byteCount = UInt64(lines[3]),
              byteCount > 0,
              byteCount <= UInt64(maximumMessageBytes),
              let sharedMemoryToken = token(sharedMemoryName: String(lines[0])) else {
            return nil
        }
        let reservationToken: UInt64
        if lines.count == 6 {
            guard lines[4].count == 16,
                  let explicitToken = UInt64(lines[4], radix: 16),
                  explicitToken == sharedMemoryToken else { return nil }
            reservationToken = explicitToken
        } else {
            reservationToken = sharedMemoryToken
        }
        guard markerName.hasSuffix(String(format: "%016llx", reservationToken)) else {
            return nil
        }
        let pageSize = UInt64(getpagesize())
        guard pageSize > 0, byteCount <= UInt64.max - (pageSize - 1) else { return nil }
        return (
            reservationToken,
            ((byteCount + pageSize - 1) / pageSize) * pageSize
        )
    }

    private nonisolated static func recoverSharedMemoryName(_ markerData: Data) -> String? {
        guard let text = String(data: markerData, encoding: .utf8),
              let first = text.split(separator: "\n", omittingEmptySubsequences: false).first else {
            return nil
        }
        let name = String(first)
        return isSharedMemoryName(name) ? name : nil
    }

    private nonisolated static func token(sharedMemoryName: String) -> UInt64? {
        guard isSharedMemoryName(sharedMemoryName) else { return nil }
        return UInt64(sharedMemoryName.dropFirst(3), radix: 16)
    }

    private nonisolated static func processExists(_ processID: Int32) -> Bool {
        guard processID > 1 else { return false }
        if Darwin.kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }

    private nonisolated static func unlinkSharedMemory(token: UInt64) {
        _ = shm_unlink(String(format: "/ch%016llx", token))
    }

    private nonisolated static func lockBudget(_ descriptor: Int32) -> Bool {
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { return false }
        }
        return true
    }

    private nonisolated static func unlockBudget(_ descriptor: Int32) {
        while flock(descriptor, LOCK_UN) != 0, errno == EINTR {}
    }

    private nonisolated static func readBudgetLedger(
        descriptor: Int32
    ) -> BudgetLedger? {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_size >= off_t(budgetHeaderBytes),
              status.st_size <= off_t(budgetHeaderBytes + maximumBudgetRecords * budgetRecordBytes),
              let data = preadData(descriptor: descriptor, count: Int(status.st_size), offset: 0),
              Array(data.prefix(8)) == budgetMagic,
              readUInt32(data, offset: 8) == budgetVersion else {
            return nil
        }
        let slotCount = Int(readUInt32(data, offset: 12))
        let maximumBytes = readUInt64(data, offset: 16)
        let recordedCount = Int(readUInt32(data, offset: 24))
        let nextSlot = Int(readUInt32(data, offset: 28))
        let recordedBytes = readUInt64(data, offset: 32)
        guard slotCount > 0, slotCount <= maximumBudgetRecords,
              maximumBytes > 0, maximumBytes <= maximumBudgetBytes,
              recordedCount >= 0, recordedCount <= slotCount,
              nextSlot >= 0, nextSlot < slotCount,
              recordedBytes <= maximumBytes,
              data.count == budgetHeaderBytes + slotCount * budgetRecordBytes else {
            return nil
        }
        var records = Array<BudgetRecord?>(repeating: nil, count: slotCount)
        var tokens: Set<UInt64> = []
        for index in 0..<slotCount {
            let offset = budgetHeaderBytes + index * budgetRecordBytes
            let token = readUInt64(data, offset: offset)
            let reservedBytes = readUInt64(data, offset: offset + 8)
            let created = readUInt64(data, offset: offset + 16)
            let ownerPID = Int32(bitPattern: readUInt32(data, offset: offset + 24))
            let state = readUInt32(data, offset: offset + 28)
            if state == 0 {
                guard token == 0, reservedBytes == 0, created == 0, ownerPID == 0 else {
                    return nil
                }
                continue
            }
            guard token != 0, reservedBytes > 0, reservedBytes <= maximumBytes,
                  tokens.insert(token).inserted,
                  state == budgetStateReserved || state == budgetStatePublished else {
                return nil
            }
            records[index] = BudgetRecord(
                token: token,
                reservedBytes: reservedBytes,
                createdNanoseconds: created,
                ownerPID: ownerPID,
                state: state
            )
        }
        let actualRecords = records.compactMap { $0 }
        let actualBytes = actualRecords.reduce(UInt64(0)) { total, record in
            total + record.reservedBytes
        }
        guard actualRecords.count == recordedCount, actualBytes == recordedBytes else {
            return nil
        }
        return BudgetLedger(slotCount: slotCount, maximumBytes: maximumBytes, records: records)
    }

    private nonisolated static func budgetHeaderData(_ ledger: BudgetLedger) -> Data {
        var data = Data(count: budgetHeaderBytes)
        data.replaceSubrange(0..<budgetMagic.count, with: budgetMagic)
        writeUInt32(budgetVersion, to: &data, offset: 8)
        writeUInt32(UInt32(ledger.slotCount), to: &data, offset: 12)
        writeUInt64(ledger.maximumBytes, to: &data, offset: 16)
        let occupiedRecords = ledger.records.compactMap { $0 }
        writeUInt32(UInt32(occupiedRecords.count), to: &data, offset: 24)
        writeUInt32(
            UInt32(ledger.records.firstIndex(where: { $0 == nil }) ?? 0),
            to: &data,
            offset: 28
        )
        writeUInt64(
            occupiedRecords.reduce(UInt64(0)) { $0 + $1.reservedBytes },
            to: &data,
            offset: 32
        )
        return data
    }

    private nonisolated static func budgetRecordData(_ record: BudgetRecord?) -> Data {
        var data = Data(count: budgetRecordBytes)
        guard let record else { return data }
        writeUInt64(record.token, to: &data, offset: 0)
        writeUInt64(record.reservedBytes, to: &data, offset: 8)
        writeUInt64(record.createdNanoseconds, to: &data, offset: 16)
        writeUInt32(UInt32(bitPattern: record.ownerPID), to: &data, offset: 24)
        writeUInt32(record.state, to: &data, offset: 28)
        return data
    }

    private nonisolated static func budgetRecordOffset(_ index: Int) -> off_t {
        off_t(budgetHeaderBytes + index * budgetRecordBytes)
    }

    private nonisolated static func persistBudgetRecords(
        _ desiredRecords: [BudgetRecord],
        existingLedger: BudgetLedger?,
        descriptor: Int32
    ) -> Bool {
        guard desiredRecords.count <= maximumBudgetRecords else { return false }
        var desiredByToken: [UInt64: BudgetRecord] = [:]
        var desiredBytes: UInt64 = 0
        for record in desiredRecords {
            guard desiredByToken.updateValue(record, forKey: record.token) == nil,
                  desiredBytes <= maximumBudgetBytes - record.reservedBytes else {
                return false
            }
            desiredBytes += record.reservedBytes
        }

        guard existingLedger != nil else {
            // Make the old header unconditionally invalid before rebuilding
            // slots. A crash before the final header therefore fails closed.
            guard pwriteData(
                descriptor: descriptor,
                data: Data(count: budgetHeaderBytes),
                offset: 0
            ), ftruncate(descriptor, 0) == 0 else { return false }
            let fileBytes = budgetHeaderBytes + maximumBudgetRecords * budgetRecordBytes
            guard ftruncate(descriptor, off_t(fileBytes)) == 0 else { return false }
            var working = BudgetLedger(
                slotCount: maximumBudgetRecords,
                maximumBytes: maximumBudgetBytes,
                records: Array(repeating: nil, count: maximumBudgetRecords)
            )
            for record in desiredRecords {
                guard let index = working.records.firstIndex(where: { $0 == nil }),
                      pwriteData(
                        descriptor: descriptor,
                        data: budgetRecordData(record),
                        offset: budgetRecordOffset(index)
                      ) else { return false }
                working.records[index] = record
            }
            return pwriteData(
                descriptor: descriptor,
                data: budgetHeaderData(working),
                offset: 0
            )
        }

        guard var working = existingLedger else { return false }

        guard desiredRecords.count <= working.slotCount,
              desiredBytes <= working.maximumBytes else { return false }
        // Removals clear their slots before decreasing the header, so a crash
        // can only overcount. Additions increment the header before filling a
        // slot, which has the same conservative failure direction.
        for index in working.records.indices {
            guard let current = working.records[index] else { continue }
            guard let desired = desiredByToken[current.token],
                  desired.reservedBytes == current.reservedBytes else {
                guard pwriteData(
                    descriptor: descriptor,
                    data: budgetRecordData(nil),
                    offset: budgetRecordOffset(index)
                ) else { return false }
                working.records[index] = nil
                continue
            }
        }
        guard pwriteData(
            descriptor: descriptor,
            data: budgetHeaderData(working),
            offset: 0
        ) else { return false }

        for index in working.records.indices {
            guard let current = working.records[index],
                  let desired = desiredByToken[current.token],
                  desired != current else { continue }
            guard pwriteData(
                descriptor: descriptor,
                data: budgetRecordData(desired),
                offset: budgetRecordOffset(index)
            ) else { return false }
            working.records[index] = desired
        }
        let existingTokens = Set(working.records.compactMap { $0?.token })
        for record in desiredRecords where !existingTokens.contains(record.token) {
            guard let index = working.records.firstIndex(where: { $0 == nil }) else {
                return false
            }
            working.records[index] = record
            guard pwriteData(
                descriptor: descriptor,
                data: budgetHeaderData(working),
                offset: 0
            ), pwriteData(
                descriptor: descriptor,
                data: budgetRecordData(record),
                offset: budgetRecordOffset(index)
            ) else { return false }
        }
        return true
    }

    private nonisolated static func preadData(
        descriptor: Int32,
        count: Int,
        offset: off_t
    ) -> Data? {
        var data = Data(count: count)
        let succeeded = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return count == 0 }
            var completed = 0
            while completed < count {
                let amount = Darwin.pread(
                    descriptor,
                    base.advanced(by: completed),
                    count - completed,
                    offset + off_t(completed)
                )
                if amount > 0 { completed += amount }
                else if amount < 0, errno == EINTR { continue }
                else { return false }
            }
            return true
        }
        return succeeded ? data : nil
    }

    private nonisolated static func pwriteData(
        descriptor: Int32,
        data: Data,
        offset: off_t
    ) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return data.isEmpty }
            var completed = 0
            while completed < data.count {
                let amount = Darwin.pwrite(
                    descriptor,
                    base.advanced(by: completed),
                    data.count - completed,
                    offset + off_t(completed)
                )
                if amount > 0 { completed += amount }
                else if amount < 0, errno == EINTR { continue }
                else { return false }
            }
            return true
        }
    }

    private nonisolated static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(data[offset + index]) << UInt32(index * 8)
        }
        return value
    }

    private nonisolated static func readUInt64(_ data: Data, offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(data[offset + index]) << UInt64(index * 8)
        }
        return value
    }

    private nonisolated static func writeUInt32(
        _ value: UInt32,
        to data: inout Data,
        offset: Int
    ) {
        for index in 0..<4 {
            data[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(index * 8))
        }
    }

    private nonisolated static func writeUInt64(
        _ value: UInt64,
        to data: inout Data,
        offset: Int
    ) {
        for index in 0..<8 {
            data[offset + index] = UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
        }
    }

    /// Scans before and after arming the vnode source, closing the publication
    /// race without treating coalesced vnode events as a per-record stream.
    func start() {
        guard !started else { return }
        started = true
        reconcile()
        installWatcher()
        reconcile()
        reconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.reconciliationInterval else { return }
                do {
                    try await ContinuousClock().sleep(
                        for: .milliseconds(Int64(interval * 1_000))
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.reconcile()
            }
        }
    }

    func stop() {
        started = false
        reconciliationTask?.cancel()
        reconciliationTask = nil
        pendingRecoveryTask?.cancel()
        pendingRecoveryTask = nil
        watcher?.cancel()
        watcher = nil
    }

#if DEBUG
    func reconcileForTesting() {
        reconcile()
    }
#endif

    private func installWatcher() {
        let descriptor = Darwin.open(
            directoryURL.path,
            O_EVTONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            agentHookDeliveryLogger.error("Could not watch hook outbox: errno=\(errno)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue(label: "com.cmuxterm.agent-hook-outbox-watch")
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.reconcileFromWatcher() }
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        watcher = source
        source.resume()
    }

    private func reconcileFromWatcher() {
        reconcile()
    }

    private func reconcile() {
        let scan = markerCandidates()
        reconcileBudgetReservations(markerTokens: Set(scan.candidates.compactMap {
            UInt64($0.publicationKey.suffix(16), radix: 16)
        }))
        schedulePendingRecovery(after: scan.nextPendingDelay)
        for candidate in scan.candidates {
            if let barrier = scan.freshPendingBarrier,
               candidate.publicationKey > barrier {
                // Do not let a later ready marker overtake a marker whose
                // writer may still be filling it.
                continue
            }
            if importRecord(markerName: candidate.name) == .blocked {
                schedulePendingRecovery(after: min(scan.nextPendingDelay ?? 0.25, 0.25))
                break
            }
        }
    }

    private func reconcileBudgetReservations(markerTokens: Set<UInt64>) {
        guard Self.lockBudget(budgetDescriptor) else { return }
        defer { Self.unlockBudget(budgetDescriptor) }
        guard let existingLedger = Self.readBudgetLedger(descriptor: budgetDescriptor) else {
            // Native publishers also reject a corrupt ledger. The next app
            // preparation recomputes it from markers before exporting access.
            return
        }
        var ledger = existingLedger
        var changed = false
        for index in ledger.records.indices {
            guard let record = ledger.records[index],
                  !markerTokens.contains(record.token),
                  !Self.processExists(record.ownerPID) else {
                continue
            }
            Self.unlinkSharedMemory(token: record.token)
            ledger.records[index] = nil
            changed = true
        }
        if changed, !Self.persistBudgetRecords(
            ledger.records.compactMap { $0 },
            existingLedger: existingLedger,
            descriptor: budgetDescriptor
        ) {
            agentHookDeliveryLogger.error("Could not reconcile hook outbox quota")
        }
    }

    private func schedulePendingRecovery(after delay: TimeInterval?) {
        pendingRecoveryTask?.cancel()
        pendingRecoveryTask = nil
        guard let delay else { return }
        pendingRecoveryTask = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(
                    for: .milliseconds(max(1, Int64(delay * 1_000)))
                )
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await self.reconcileAfterPendingGrace()
        }
    }

    private func reconcileAfterPendingGrace() {
        pendingRecoveryTask = nil
        reconcile()
    }

    private func markerCandidates() -> MarkerScan {
        // dup(2) shares the directory offset, so a prior EOF would make every
        // later reconciliation empty. Open a fresh file description instead.
        let scanDescriptor = openat(
            directoryDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard scanDescriptor >= 0, let directory = fdopendir(scanDescriptor) else {
            if scanDescriptor >= 0 { Darwin.close(scanDescriptor) }
            return MarkerScan()
        }
        defer { closedir(directory) }

        let now = Date().timeIntervalSince1970
        var scan = MarkerScan()
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) {
                    String(cString: $0)
                }
            }
            if let publicationKey = Self.publicationKey(
                markerName: name,
                prefix: Self.readyMarkerPrefix
            ) {
                scan.candidates.append(MarkerCandidate(
                    name: name,
                    publicationKey: publicationKey,
                    isPending: false
                ))
            } else if let publicationKey = Self.publicationKey(
                markerName: name,
                prefix: Self.pendingMarkerPrefix
            ) {
                switch pendingMarkerState(name: name, now: now) {
                case .stale:
                    scan.candidates.append(MarkerCandidate(
                        name: name,
                        publicationKey: publicationKey,
                        isPending: true
                    ))
                case .fresh(let remainingGrace):
                    scan.freshPendingBarrier = min(
                        scan.freshPendingBarrier ?? publicationKey,
                        publicationKey
                    )
                    scan.nextPendingDelay = min(
                        scan.nextPendingDelay ?? remainingGrace,
                        remainingGrace
                    )
                case .retryable:
                    scan.freshPendingBarrier = min(
                        scan.freshPendingBarrier ?? publicationKey,
                        publicationKey
                    )
                    scan.nextPendingDelay = min(scan.nextPendingDelay ?? 0.05, 0.05)
                case .missing:
                    break
                }
            }
        }
        scan.candidates.sort { left, right in
            if left.publicationKey != right.publicationKey {
                return left.publicationKey < right.publicationKey
            }
            // If a crash or filesystem anomaly leaves both names behind, the
            // committed ready name is authoritative.
            return !left.isPending && right.isPending
        }
        return scan
    }

    private static func publicationKey(markerName name: String, prefix: String) -> String? {
        guard name.utf8.count == prefix.utf8.count + 16 + 1 + 16,
              name.hasPrefix(prefix) else {
            return nil
        }
        let suffix = name.dropFirst(prefix.count)
        guard suffix[suffix.index(suffix.startIndex, offsetBy: 16)] == "-" else {
            return nil
        }
        guard suffix.enumerated().allSatisfy({ index, character in
            index == 16 ? character == "-" : character.isHexDigit && !character.isUppercase
        }) else { return nil }
        return String(suffix)
    }

    private func pendingMarkerState(
        name: String,
        now: TimeInterval
    ) -> PendingMarkerState {
        var status = stat()
        guard fstatat(
            directoryDescriptor,
            name,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            let code = errno
            if code == ENOENT { return .missing }
            return Self.isRetryableIOError(code) ? .retryable : .stale
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid() else {
            return .stale
        }
        let modifiedAt = TimeInterval(status.st_mtimespec.tv_sec)
            + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        let age = max(0, now - modifiedAt)
        let remainingGrace = max(0, pendingRecoveryGrace - age)
        return remainingGrace == 0 ? .stale : .fresh(remainingGrace: remainingGrace)
    }

    private func importRecord(markerName: String) -> ImportRecordResult {
        let marker: Marker
        switch readMarker(named: markerName) {
        case .valid(let validMarker):
            marker = validMarker
        case .malformed(let sharedMemoryName):
            cleanup(
                markerName: markerName,
                sharedMemoryName: sharedMemoryName,
                reservationToken: sharedMemoryName.flatMap {
                    Self.token(sharedMemoryName: $0)
                }
            )
            return .advanced
        case .missing, .retryable:
            return .blocked
        }
        let message: Data
        switch readSharedMemory(marker) {
        case .data(let data):
            message = data
        case .invalid:
            cleanup(
                markerName: markerName,
                sharedMemoryName: marker.sharedMemoryName,
                reservationToken: marker.reservationToken
            )
            return .advanced
        case .retryable:
            return .blocked
        }
        guard capabilityAuthority.verifiesOutboxMessage(
            nonce: marker.nonce,
            code: marker.code,
            message: message
        ), let event = Self.event(from: message) else {
            agentHookDeliveryLogger.error("Rejected unauthenticated or malformed hook outbox record")
            cleanup(
                markerName: markerName,
                sharedMemoryName: marker.sharedMemoryName,
                reservationToken: marker.reservationToken
            )
            return .advanced
        }

        do {
            try deliveryQueue.enqueue(event)
        } catch {
            // SQLite availability errors are retryable. Keep both names until
            // the next vnode or periodic reconciliation pass.
            agentHookDeliveryLogger.error(
                "Could not import hook outbox record: \(error.localizedDescription, privacy: .private)"
            )
            return .blocked
        }
        cleanup(
            markerName: markerName,
            sharedMemoryName: marker.sharedMemoryName,
            reservationToken: marker.reservationToken
        )
        return .advanced
    }

    private func readMarker(named name: String) -> MarkerReadResult {
        let descriptor = openat(
            directoryDescriptor,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT { return .missing }
            return Self.isRetryableIOError(code)
                ? .retryable
                : .malformed(sharedMemoryName: nil)
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            return Self.isRetryableIOError(errno)
                ? .retryable
                : .malformed(sharedMemoryName: nil)
        }
        guard
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              (status.st_mode & 0o777) == 0o600,
              status.st_size > 0,
              status.st_size <= off_t(Self.maximumMarkerBytes) else {
            return .malformed(sharedMemoryName: nil)
        }
        let data: Data
        switch Self.readRegularFile(descriptor: descriptor, count: Int(status.st_size)) {
        case .data(let value):
            data = value
        case .malformed:
            return .malformed(sharedMemoryName: nil)
        case .retryable:
            return .retryable
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .malformed(sharedMemoryName: nil)
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let sharedMemoryName = lines.first.map(String.init).flatMap {
            Self.isSharedMemoryName($0) ? $0 : nil
        }
        guard (lines.count == 5 || lines.count == 6),
              lines.last?.isEmpty == true,
              let sharedMemoryName,
              !lines[1].isEmpty,
              lines[1].utf8.count < 65,
              let code = Data(base64Encoded: String(lines[2])),
              code.count == 32,
              let byteCount = Int(lines[3]),
              byteCount > 0,
              byteCount <= Self.maximumMessageBytes else {
            return .malformed(sharedMemoryName: sharedMemoryName)
        }
        guard let sharedMemoryToken = Self.token(sharedMemoryName: sharedMemoryName) else {
            return .malformed(sharedMemoryName: sharedMemoryName)
        }
        let reservationToken: UInt64
        if lines.count == 6 {
            guard lines[4].count == 16,
                  let explicitToken = UInt64(lines[4], radix: 16),
                  explicitToken == sharedMemoryToken,
                  name.hasSuffix(String(format: "%016llx", explicitToken)) else {
                return .malformed(sharedMemoryName: sharedMemoryName)
            }
            reservationToken = explicitToken
        } else {
            reservationToken = sharedMemoryToken
        }
        return .valid(Marker(
            sharedMemoryName: sharedMemoryName,
            nonce: String(lines[1]),
            code: code,
            byteCount: byteCount,
            reservationToken: reservationToken
        ))
    }

    private static func isSharedMemoryName(_ name: String) -> Bool {
        guard name.utf8.count == 19, name.hasPrefix("/ch") else { return false }
        return name.dropFirst(3).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private func readSharedMemory(_ marker: Marker) -> SharedMemoryReadResult {
        if let injectedError = sharedMemoryReadErrorForTesting?() {
            return Self.isRetryableIOError(injectedError) ? .retryable : .invalid
        }
        let descriptor = marker.sharedMemoryName.withCString {
            cmux_agent_hook_shm_open_readonly($0)
        }
        guard descriptor >= 0 else {
            return Self.isRetryableIOError(errno) ? .retryable : .invalid
        }
        defer { Darwin.close(descriptor) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            return Self.isRetryableIOError(errno) ? .retryable : .invalid
        }
        let pageSize = Int(getpagesize())
        guard pageSize > 0,
              marker.byteCount <= Int(off_t.max),
              marker.byteCount <= Int.max - (pageSize - 1) else {
            return .invalid
        }
        let expectedSize = off_t(
            ((marker.byteCount + pageSize - 1) / pageSize) * pageSize
        )
        guard
              status.st_uid == geteuid(),
              (status.st_mode & 0o777) == 0o600,
              status.st_size == expectedSize else {
            return .invalid
        }
        let mapping = mmap(
            nil,
            marker.byteCount,
            PROT_READ,
            MAP_SHARED,
            descriptor,
            0
        )
        guard mapping != MAP_FAILED else {
            return Self.isRetryableIOError(errno) ? .retryable : .invalid
        }
        defer { munmap(mapping, marker.byteCount) }
        return .data(Data(bytes: mapping!, count: marker.byteCount))
    }

    private static func readRegularFile(descriptor: Int32, count: Int) -> FileReadResult {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { bytes -> FileReadResult in
            guard let baseAddress = bytes.baseAddress else {
                return count == 0 ? .data(Data()) : .malformed
            }
            var offset = 0
            while offset < count {
                let amount = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    count - offset
                )
                if amount > 0 {
                    offset += amount
                } else if amount < 0, errno == EINTR {
                    continue
                } else if amount < 0, Self.isRetryableIOError(errno) {
                    return .retryable
                } else {
                    return .malformed
                }
            }
            return .data(Data())
        }
        switch result {
        case .data:
            return .data(data)
        case .malformed:
            return .malformed
        case .retryable:
            return .retryable
        }
    }

    private static func event(from message: Data) -> AgentHookDeliveryEvent? {
        guard let request = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
              request["method"] as? String == "agent.hook.enqueue",
              let params = request["params"] as? [String: Any] else {
            return nil
        }
        return AgentHookDeliveryEvent(params: params)
    }

    private func cleanup(
        markerName: String,
        sharedMemoryName: String?,
        reservationToken: UInt64?
    ) {
        if let sharedMemoryName, Self.isSharedMemoryName(sharedMemoryName) {
            _ = shm_unlink(sharedMemoryName)
        }
        _ = unlinkat(directoryDescriptor, markerName, 0)
        if let reservationToken {
            releaseBudgetReservation(token: reservationToken)
        }
    }

    private func releaseBudgetReservation(token: UInt64) {
        guard Self.lockBudget(budgetDescriptor) else { return }
        defer { Self.unlockBudget(budgetDescriptor) }
        guard let existingLedger = Self.readBudgetLedger(descriptor: budgetDescriptor) else {
            return
        }
        var ledger = existingLedger
        guard let index = ledger.records.firstIndex(where: { $0?.token == token }) else {
            return
        }
        ledger.records[index] = nil
        if !Self.persistBudgetRecords(
            ledger.records.compactMap { $0 },
            existingLedger: existingLedger,
            descriptor: budgetDescriptor
        ) {
            agentHookDeliveryLogger.error("Could not release hook outbox quota")
        }
    }
}

/// Commits wrapper hooks to a local WAL before acknowledgement, then delivers
/// them through bounded per-surface lanes. The WAL survives app-process
/// crashes; SQLite keeps it consistent across a machine crash.
actor AgentHookDeliveryQueue {
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let hardMaximumConcurrentDeliveries = 32
    private static let maximumPendingDeliveries = 4_096
    private static let maximumPendingBytes = 64 * 1024 * 1024
    private static let maximumDeliveredReceipts = 4_096
    private static let maximumPhysicalDatabaseBytes = 256 * 1024 * 1024
    private static let maximumWALBytes = 16 * 1024 * 1024

    private struct PendingDelivery: Sendable {
        let sequence: Int64
        let deliveryID: String
        let orderingKey: String
        let agent: String
        let subcommand: String
        let payload: Data
        let socketPath: String
        let environment: [String: String]
        let attempts: Int
    }

    private struct DeliveryCompletion: Sendable {
        let delivery: PendingDelivery
        let succeeded: Bool
        let error: String?
        let lingeringProcessGroup: ProcessGroupPermit?
    }

    private struct ProcessGroupPermit: Sendable {
        let processGroupID: pid_t
        let deadline: TimeInterval
    }

    private struct DeliveryAttemptResult: Sendable {
        let succeeded: Bool
        let error: String?
        let lingeringProcessGroup: ProcessGroupPermit?

        static func failure(_ error: String) -> Self {
            Self(succeeded: false, error: error, lingeringProcessGroup: nil)
        }
    }

    private enum DrainCompletion: Sendable {
        case delivery(DeliveryCompletion)
        case processGroupReleased(pid_t)
        case deliveryAvailable
    }

    private struct DeliveryWakeChannel: Sendable {
        let stream: AsyncStream<Void>
        let continuation: AsyncStream<Void>.Continuation

        init() {
            (stream, continuation) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
        }
    }

    private enum DeliveryProcessRace: Sendable {
        case exited(Int32)
        case deadline
        case cancelled
    }

    private let databaseURL: URL
    // SQLite serializes this FULLMUTEX connection. `enqueue` must remain
    // synchronous so the socket cannot acknowledge before the committed insert.
    nonisolated(unsafe) private let database: OpaquePointer?
    nonisolated private let databaseInitializationError: String?
    nonisolated private let admissionLock = NSLock()
    nonisolated private let ephemeralEnvironmentStore = AgentHookEphemeralEnvironmentStore()
    private let executableURLProvider: @Sendable () -> URL?
    private let processTimeout: TimeInterval
    private let lingeringProcessGroupTimeout: TimeInterval
    private let terminationGrace: TimeInterval
    private let retryBaseDelay: TimeInterval
    private let retryMaximumDelay: TimeInterval
    private let deliveredReceiptRetention: TimeInterval
    private let maximumConcurrentDeliveries: Int
#if DEBUG
    private let afterDurableCommitForTesting: (@Sendable (String) -> Void)?
#endif

    private var drainTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var drainRequested = false
    private var deliveredSinceReceiptCleanup = 0
    private let deliveryWakeChannel = DeliveryWakeChannel()

    init(
        databaseURL: URL? = nil,
        executableURLProvider: @escaping @Sendable () -> URL? = {
            Bundle.main.resourceURL?.appendingPathComponent("bin/cmux", isDirectory: false)
        },
        processTimeout: TimeInterval = 15,
        lingeringProcessGroupTimeout: TimeInterval = 75,
        terminationGrace: TimeInterval = 0.5,
        retryBaseDelay: TimeInterval = 0.25,
        retryMaximumDelay: TimeInterval = 300,
        deliveredReceiptRetention: TimeInterval = 86_400,
        maximumConcurrentDeliveries: Int = 32,
        afterDurableCommitForTesting: (@Sendable (String) -> Void)? = nil
    ) {
        let resolvedDatabaseURL = databaseURL ?? Self.defaultDatabaseURL()
        self.databaseURL = resolvedDatabaseURL
        self.executableURLProvider = executableURLProvider
        self.processTimeout = max(0.01, processTimeout)
        self.lingeringProcessGroupTimeout = max(0.01, lingeringProcessGroupTimeout)
        self.terminationGrace = max(0.01, terminationGrace)
        self.retryBaseDelay = max(0.01, retryBaseDelay)
        self.retryMaximumDelay = max(self.retryBaseDelay, retryMaximumDelay)
        self.deliveredReceiptRetention = max(60, deliveredReceiptRetention)
        self.maximumConcurrentDeliveries = min(
            Self.hardMaximumConcurrentDeliveries,
            max(1, maximumConcurrentDeliveries)
        )
#if DEBUG
        self.afterDurableCommitForTesting = afterDurableCommitForTesting
#endif

        do {
            self.database = try Self.openDatabase(at: resolvedDatabaseURL)
            self.databaseInitializationError = nil
        } catch {
            self.database = nil
            self.databaseInitializationError = error.localizedDescription
            agentHookDeliveryLogger.fault("Could not open delivery queue: \(error.localizedDescription, privacy: .private)")
        }

        // A previous app process may have exited after acceptance but before
        // delivery. Resume those durable rows as soon as this queue is created.
        Task { [weak self] in
            await self?.deliveryAvailable()
        }
    }

    deinit {
        drainTask?.cancel()
        retryTask?.cancel()
        deliveryWakeChannel.continuation.finish()
        if let database {
            sqlite3_close_v2(database)
        }
    }

    /// Commits an event before the socket acknowledges it. Duplicate delivery
    /// IDs with identical contents are successful no-ops.
    nonisolated func enqueue(_ event: AgentHookDeliveryEvent) throws {
        guard let database else {
            throw Self.failure(
                databaseInitializationError ?? "Agent hook delivery database is unavailable.",
                code: 1
            )
        }
        let environmentData = try JSONSerialization.data(
            withJSONObject: event.durableEnvironment,
            options: [.sortedKeys]
        )
        let retainedBytes = [
            event.deliveryID.utf8.count,
            event.orderingKey.utf8.count,
            event.contentDigest.count,
            event.agent.utf8.count,
            event.subcommand.utf8.count,
            event.payload.count,
            event.socketPath.utf8.count,
            environmentData.count,
        ].reduce(0, +)
        admissionLock.lock()
        defer { admissionLock.unlock() }

        if let storedDigest = try Self.storedDigest(for: event.deliveryID, database: database) {
            guard storedDigest == event.contentDigest else {
                throw Self.failure(
                    "Delivery ID \(event.deliveryID) was reused for different hook contents.",
                    code: 2
                )
            }
            if try Self.storedDeliveryIsPending(for: event.deliveryID, database: database) {
                guard ephemeralEnvironmentStore.replace(
                    event.ephemeralEnvironment,
                    for: event.deliveryID
                ) else {
                    throw Self.failure("Pending hook credential memory budget is full.", code: 13)
                }
                do {
                    if try !Self.storedDeliveryIsPending(for: event.deliveryID, database: database) {
                        ephemeralEnvironmentStore.remove(deliveryID: event.deliveryID)
                    }
                } catch {
                    ephemeralEnvironmentStore.remove(deliveryID: event.deliveryID)
                    throw error
                }
            } else {
                ephemeralEnvironmentStore.remove(deliveryID: event.deliveryID)
            }
            agentHookDeliveryLogger.debug("Accepted duplicate hook \(event.deliveryID, privacy: .public)")
            Task { [weak self] in
                await self?.deliveryAvailable()
            }
            return
        }

        let now = Date().timeIntervalSince1970
        let insertSQL = """
        INSERT INTO agent_hook_deliveries (
            delivery_id, ordering_key, content_digest, agent, subcommand, payload,
            socket_path, environment_json, retained_bytes, accepted_at, next_attempt_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        var status = sqlite3_prepare_v2(database, insertSQL, -1, &statement, nil)
        guard status == SQLITE_OK else {
            throw Self.sqliteFailure(status, operation: "prepare durable insert")
        }
        defer { sqlite3_finalize(statement) }

        status = Self.bind(event.deliveryID, to: statement, at: 1)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind delivery ID") }
        status = Self.bind(event.orderingKey, to: statement, at: 2)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind ordering key") }
        status = Self.bind(event.contentDigest, to: statement, at: 3)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind digest") }
        status = Self.bind(event.agent, to: statement, at: 4)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind agent") }
        status = Self.bind(event.subcommand, to: statement, at: 5)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind subcommand") }
        status = Self.bind(event.payload, to: statement, at: 6)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind payload") }
        status = Self.bind(event.socketPath, to: statement, at: 7)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind socket path") }
        status = Self.bind(environmentData, to: statement, at: 8)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind environment") }
        status = sqlite3_bind_int64(statement, 9, Int64(retainedBytes))
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind retained bytes") }
        status = sqlite3_bind_double(statement, 10, now)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind acceptance time") }
        status = sqlite3_bind_double(statement, 11, now)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind retry time") }

        // Publish credentials before the committed row can become visible to
        // an already-running drain. The admission lock serializes the
        // preflight duplicate check with this publication/insert pair.
        guard ephemeralEnvironmentStore.replace(
            event.ephemeralEnvironment,
            for: event.deliveryID
        ) else {
            throw Self.failure("Pending hook credential memory budget is full.", code: 13)
        }
        status = sqlite3_step(statement)
        guard status == SQLITE_DONE else {
            ephemeralEnvironmentStore.remove(deliveryID: event.deliveryID)
            throw Self.sqliteFailure(status, operation: "persist accepted delivery")
        }
#if DEBUG
        afterDurableCommitForTesting?(event.deliveryID)
#endif

        agentHookDeliveryLogger.debug("Accepted hook \(event.deliveryID, privacy: .public)")
        Task { [weak self] in
            await self?.deliveryAvailable()
        }
    }

    /// Makes every undelivered row immediately eligible again. This is also a
    /// diagnostics seam for explicit recovery after an external dependency is fixed.
    func retryPendingDeliveries() throws {
        guard let database else {
            throw Self.failure(databaseInitializationError ?? "Delivery database is unavailable.", code: 3)
        }
        let status = sqlite3_exec(
            database,
            "UPDATE agent_hook_deliveries SET next_attempt_at = 0 WHERE delivered_at IS NULL;",
            nil,
            nil,
            nil
        )
        guard status == SQLITE_OK else {
            throw Self.sqliteFailure(status, operation: "retry pending deliveries")
        }
        deliveryAvailable()
    }

    /// Returns durable state for diagnostics without loading payloads into memory.
    func diagnosticStatus(for deliveryID: String) throws -> [String: String]? {
        guard let database else {
            throw Self.failure(databaseInitializationError ?? "Delivery database is unavailable.", code: 4)
        }
        let sql = """
        SELECT attempts, delivered_at, next_attempt_at, COALESCE(last_error, '')
        FROM agent_hook_deliveries WHERE delivery_id = ? LIMIT 1;
        """
        var statement: OpaquePointer?
        var status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK else {
            throw Self.sqliteFailure(status, operation: "prepare delivery status")
        }
        defer { sqlite3_finalize(statement) }
        status = Self.bind(deliveryID, to: statement, at: 1)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind status ID") }
        status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else {
            throw Self.sqliteFailure(status, operation: "read delivery status")
        }

        let delivered = sqlite3_column_type(statement, 1) != SQLITE_NULL
        return [
            "state": delivered ? "delivered" : "pending",
            "attempts": String(sqlite3_column_int(statement, 0)),
            "next_attempt_at": String(sqlite3_column_double(statement, 2)),
            "last_error": Self.columnText(statement, at: 3) ?? "",
        ]
    }

    /// Waits for the active drain pass. A future backoff deadline is not an
    /// active pass, so callers can inspect durable pending state afterward.
    func waitUntilCurrentDrainFinishes() async {
        deliveryAvailable()
        while let drainTask {
            await drainTask.value
        }
    }

    private func deliveryAvailable() {
        retryTask?.cancel()
        retryTask = nil
        guard database != nil else { return }
        if drainTask != nil {
            drainRequested = true
            // A retained descendant can outlive its delivery leader. Wake the
            // drain immediately when new durable work arrives instead of
            // waiting for that descendant's process group to exit.
            deliveryWakeChannel.continuation.yield(())
            return
        }
        drainRequested = false
        drainTask = Task { [weak self] in
            let needsRecovery = await self?.drainAvailableDeliveries() ?? false
            await self?.drainDidFinish(needsRecovery: needsRecovery)
        }
    }

    private func drainDidFinish(needsRecovery: Bool) {
        drainTask = nil
        if drainRequested {
            drainRequested = false
            deliveryAvailable()
        } else if needsRecovery {
            scheduleQueueRecovery(after: retryBaseDelay)
        }
    }

#if DEBUG
    func cancelCurrentDrainForTesting() async {
        guard let drainTask else { return }
        drainTask.cancel()
        await drainTask.value
    }
#endif

    private func drainAvailableDeliveries() async -> Bool {
        guard let database else { return false }

        return await withTaskGroup(of: DrainCompletion.self) { group in
            var activeSequences: Set<Int64> = []
            var activeOrderingKeys: Set<String> = []
            var retainedProcessGroups: Set<pid_t> = []
            let deliveryWakeStream = deliveryWakeChannel.stream
            group.addTask {
                var iterator = deliveryWakeStream.makeAsyncIterator()
                _ = await iterator.next()
                return .deliveryAvailable
            }

            while !Task.isCancelled {
                do {
                    let occupiedPermits = activeSequences.count + retainedProcessGroups.count
                    guard occupiedPermits <= maximumConcurrentDeliveries else {
                        throw Self.failure(
                            "Delivery process-group permit budget was exceeded.",
                            code: 10
                        )
                    }
                    let capacity = maximumConcurrentDeliveries - occupiedPermits
                    var launchedDelivery = false
                    if capacity > 0 {
                        let deliveries = try nextDueDeliveries(
                            database: database,
                            excludingSequences: activeSequences,
                            limit: capacity
                        )
                        for delivery in deliveries {
                            guard activeOrderingKeys.insert(delivery.orderingKey).inserted else {
                                throw Self.failure(
                                    "Delivery scheduler selected an ordering key twice.",
                                    code: 9
                                )
                            }
                            try markAttemptStarted(sequence: delivery.sequence, database: database)
                            activeSequences.insert(delivery.sequence)
                            launchedDelivery = true
                            group.addTask { [self] in
                                let result = await deliver(
                                    agent: delivery.agent,
                                    subcommand: delivery.subcommand,
                                    payload: delivery.payload,
                                    socketPath: delivery.socketPath,
                                    environment: delivery.environment,
                                    deliveryID: delivery.deliveryID
                                )
                                return .delivery(DeliveryCompletion(
                                    delivery: delivery,
                                    succeeded: result.succeeded,
                                    error: result.error,
                                    lingeringProcessGroup: result.lingeringProcessGroup
                                ))
                            }
                        }
                    }

                    if activeSequences.isEmpty, retainedProcessGroups.isEmpty {
                        try deleteExpiredReceipts(database: database)
                        try scheduleNextRetry(database: database)
                        group.cancelAll()
                        return false
                    }
                    if launchedDelivery,
                       activeSequences.count + retainedProcessGroups.count
                            < maximumConcurrentDeliveries {
                        continue
                    }

                    guard let completion = await group.next() else { return false }
                    switch completion {
                    case .delivery(let deliveryCompletion):
                        activeSequences.remove(deliveryCompletion.delivery.sequence)
                        activeOrderingKeys.remove(deliveryCompletion.delivery.orderingKey)
                        if let permit = deliveryCompletion.lingeringProcessGroup,
                           Self.processGroupExists(permit.processGroupID) {
                            guard retainedProcessGroups.insert(permit.processGroupID).inserted else {
                                throw Self.failure(
                                    "Delivery process-group permit was transferred twice.",
                                    code: 11
                                )
                            }
                            let monitorTerminationGrace = self.terminationGrace
                            group.addTask {
                                await Self.monitorProcessGroup(
                                    permit,
                                    terminationGrace: monitorTerminationGrace
                                )
                                return .processGroupReleased(permit.processGroupID)
                            }
                        }
                        try record(completion: deliveryCompletion, database: database)
                    case .processGroupReleased(let processGroupID):
                        guard retainedProcessGroups.remove(processGroupID) != nil else {
                            throw Self.failure(
                                "Delivery process-group permit was released twice.",
                                code: 12
                            )
                        }
                    case .deliveryAvailable:
                        drainRequested = false
                        group.addTask {
                            var iterator = deliveryWakeStream.makeAsyncIterator()
                            _ = await iterator.next()
                            return .deliveryAvailable
                        }
                    }
                } catch {
                    group.cancelAll()
                    while let completion = await group.next() {
                        if case .delivery(let deliveryCompletion) = completion,
                           let permit = deliveryCompletion.lingeringProcessGroup {
                            Self.forceKillProcessGroup(permit.processGroupID)
                        }
                    }
                    agentHookDeliveryLogger.fault(
                        "Delivery queue drain failed: \(error.localizedDescription, privacy: .private)"
                    )
                    return true
                }
            }
            group.cancelAll()
            while let completion = await group.next() {
                if case .delivery(let deliveryCompletion) = completion,
                   let permit = deliveryCompletion.lingeringProcessGroup {
                    Self.forceKillProcessGroup(permit.processGroupID)
                }
            }
            return true
        }
    }

    private func record(completion: DeliveryCompletion, database: OpaquePointer) throws {
        let delivery = completion.delivery
        if completion.succeeded {
            try markDelivered(sequence: delivery.sequence, database: database)
            ephemeralEnvironmentStore.remove(deliveryID: delivery.deliveryID)
            deliveredSinceReceiptCleanup += 1
            if deliveredSinceReceiptCleanup >= 128 {
                try deleteExpiredReceipts(database: database)
                deliveredSinceReceiptCleanup = 0
            }
            agentHookDeliveryLogger.debug("Delivered hook \(delivery.deliveryID, privacy: .public)")
            return
        }

        let attempt = delivery.attempts + 1
        let delay = min(
            retryMaximumDelay,
            retryBaseDelay * pow(4, Double(min(attempt - 1, 8)))
        )
        let detail = completion.error ?? "Unknown delivery failure"
        try markFailed(
            sequence: delivery.sequence,
            nextAttemptAt: Date().timeIntervalSince1970 + delay,
            error: detail,
            database: database
        )
        agentHookDeliveryLogger.error(
            "Hook \(delivery.deliveryID, privacy: .public) failed; retrying in \(delay, privacy: .public)s: \(detail, privacy: .private)"
        )
    }

    private func nextDueDeliveries(
        database: OpaquePointer,
        excludingSequences: Set<Int64>,
        limit: Int
    ) throws -> [PendingDelivery] {
        guard limit > 0 else { return [] }
        let orderedExclusions = excludingSequences.sorted()
        let exclusionSQL: String
        if orderedExclusions.isEmpty {
            exclusionSQL = ""
        } else {
            exclusionSQL = "AND d.sequence NOT IN (\(Array(repeating: "?", count: orderedExclusions.count).joined(separator: ", ")))"
        }
        let sql = """
        SELECT d.sequence, d.delivery_id, d.ordering_key, d.agent, d.subcommand,
               d.payload, d.socket_path, d.environment_json, d.attempts
        FROM agent_hook_deliveries AS d
        WHERE d.delivered_at IS NULL
          AND d.next_attempt_at <= ?
          \(exclusionSQL)
          AND NOT EXISTS (
              SELECT 1
              FROM agent_hook_deliveries AS earlier
              WHERE earlier.delivered_at IS NULL
                AND (earlier.ordering_key = d.ordering_key OR earlier.ordering_key = '')
                AND earlier.sequence < d.sequence
          )
        ORDER BY d.sequence ASC
        LIMIT ?;
        """
        var statement: OpaquePointer?
        var status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK else {
            throw Self.sqliteFailure(status, operation: "prepare due deliveries")
        }
        defer { sqlite3_finalize(statement) }
        status = sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind delivery deadline") }
        var bindingIndex: Int32 = 2
        for sequence in orderedExclusions {
            status = sqlite3_bind_int64(statement, bindingIndex, sequence)
            guard status == SQLITE_OK else {
                throw Self.sqliteFailure(status, operation: "bind active delivery exclusion")
            }
            bindingIndex += 1
        }
        status = sqlite3_bind_int(statement, bindingIndex, Int32(limit))
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind delivery limit") }

        var deliveries: [PendingDelivery] = []
        deliveries.reserveCapacity(limit)
        while true {
            status = sqlite3_step(statement)
            if status == SQLITE_DONE { return deliveries }
            guard status == SQLITE_ROW,
                  let deliveryID = Self.columnText(statement, at: 1),
                  let orderingKey = Self.columnText(statement, at: 2),
                  let agent = Self.columnText(statement, at: 3),
                  let subcommand = Self.columnText(statement, at: 4),
                  let payload = Self.columnData(statement, at: 5),
                  let socketPath = Self.columnText(statement, at: 6),
                  let environmentData = Self.columnData(statement, at: 7),
                  let environment = try JSONSerialization.jsonObject(with: environmentData) as? [String: String] else {
                throw Self.failure("Stored delivery row is malformed.", code: 5)
            }
            deliveries.append(PendingDelivery(
                sequence: sqlite3_column_int64(statement, 0),
                deliveryID: deliveryID,
                orderingKey: orderingKey,
                agent: agent,
                subcommand: subcommand,
                payload: payload,
                socketPath: socketPath,
                environment: environment,
                attempts: Int(sqlite3_column_int(statement, 8))
            ))
        }
    }

    private func markAttemptStarted(sequence: Int64, database: OpaquePointer) throws {
        try executeUpdate(
            "UPDATE agent_hook_deliveries SET attempts = attempts + 1, last_attempt_at = ? WHERE sequence = ?;",
            timestamp: Date().timeIntervalSince1970,
            sequence: sequence,
            database: database,
            operation: "mark delivery attempt"
        )
    }

    private func markDelivered(sequence: Int64, database: OpaquePointer) throws {
        let sql = """
        UPDATE agent_hook_deliveries
        SET delivered_at = ?, next_attempt_at = 0, last_error = NULL,
            payload = X'', socket_path = '', environment_json = X'7B7D', retained_bytes = 0
        WHERE sequence = ?;
        """
        try executeUpdate(
            sql,
            timestamp: Date().timeIntervalSince1970,
            sequence: sequence,
            database: database,
            operation: "mark delivery complete"
        )
    }

    private func markFailed(
        sequence: Int64,
        nextAttemptAt: TimeInterval,
        error: String,
        database: OpaquePointer
    ) throws {
        let sql = """
        UPDATE agent_hook_deliveries
        SET next_attempt_at = ?, last_error = ?
        WHERE sequence = ?;
        """
        var statement: OpaquePointer?
        var status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK else {
            throw Self.sqliteFailure(status, operation: "prepare failed delivery update")
        }
        defer { sqlite3_finalize(statement) }
        status = sqlite3_bind_double(statement, 1, nextAttemptAt)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind retry time") }
        status = Self.bind(String(error.prefix(4_096)), to: statement, at: 2)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind delivery error") }
        status = sqlite3_bind_int64(statement, 3, sequence)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind failed sequence") }
        status = sqlite3_step(statement)
        guard status == SQLITE_DONE else {
            throw Self.sqliteFailure(status, operation: "record failed delivery")
        }
    }

    private func executeUpdate(
        _ sql: String,
        timestamp: TimeInterval,
        sequence: Int64,
        database: OpaquePointer,
        operation: String
    ) throws {
        var statement: OpaquePointer?
        var status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "prepare \(operation)") }
        defer { sqlite3_finalize(statement) }
        status = sqlite3_bind_double(statement, 1, timestamp)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind \(operation) time") }
        status = sqlite3_bind_int64(statement, 2, sequence)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind \(operation) sequence") }
        status = sqlite3_step(statement)
        guard status == SQLITE_DONE else { throw Self.sqliteFailure(status, operation: operation) }
    }

    private func deleteExpiredReceipts(database: OpaquePointer) throws {
        let cutoff = Date().timeIntervalSince1970 - deliveredReceiptRetention
        var statement: OpaquePointer?
        var status = sqlite3_prepare_v2(
            database,
            "DELETE FROM agent_hook_deliveries WHERE delivered_at IS NOT NULL AND delivered_at < ?;",
            -1,
            &statement,
            nil
        )
        guard status == SQLITE_OK else {
            throw Self.sqliteFailure(status, operation: "prepare receipt cleanup")
        }
        defer { sqlite3_finalize(statement) }
        status = sqlite3_bind_double(statement, 1, cutoff)
        guard status == SQLITE_OK else { throw Self.sqliteFailure(status, operation: "bind receipt cutoff") }
        status = sqlite3_step(statement)
        guard status == SQLITE_DONE else { throw Self.sqliteFailure(status, operation: "delete expired receipts") }
    }

    private func scheduleNextRetry(database: OpaquePointer) throws {
        var statement: OpaquePointer?
        var status = sqlite3_prepare_v2(
            database,
            """
            SELECT MIN(d.next_attempt_at)
            FROM agent_hook_deliveries AS d
            WHERE d.delivered_at IS NULL
              AND NOT EXISTS (
                  SELECT 1
                  FROM agent_hook_deliveries AS earlier
                  WHERE earlier.delivered_at IS NULL
                    AND (earlier.ordering_key = d.ordering_key OR earlier.ordering_key = '')
                    AND earlier.sequence < d.sequence
              );
            """,
            -1,
            &statement,
            nil
        )
        guard status == SQLITE_OK else {
            throw Self.sqliteFailure(status, operation: "prepare retry deadline")
        }
        defer { sqlite3_finalize(statement) }
        status = sqlite3_step(statement)
        guard status == SQLITE_ROW else { throw Self.sqliteFailure(status, operation: "read retry deadline") }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return }
        let deadline = sqlite3_column_double(statement, 0)
        scheduleQueueRecovery(after: max(0.01, deadline - Date().timeIntervalSince1970))
    }

    private func scheduleQueueRecovery(after delay: TimeInterval) {
        retryTask?.cancel()
        let boundedDelay = min(retryMaximumDelay, max(0.01, delay))
        retryTask = Task { [weak self] in
            do {
                // This is the queue's real retry deadline, not a polling sleep.
                try await ContinuousClock().sleep(for: .milliseconds(Int64(boundedDelay * 1_000)))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.retryDeadlineReached()
        }
    }

    private func retryDeadlineReached() {
        retryTask = nil
        deliveryAvailable()
    }

    private func deliver(
        agent: String,
        subcommand: String,
        payload: Data,
        socketPath: String,
        environment eventEnvironment: [String: String],
        deliveryID: String
    ) async -> DeliveryAttemptResult {
        guard let executableURL = executableURLProvider(),
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return .failure("Bundled cmux CLI is unavailable or not executable.")
        }

        let input: FileHandle
        let errorOutput: FileHandle
        do {
            input = try Self.anonymousFile(containing: payload, near: databaseURL)
            errorOutput = try Self.anonymousFile(containing: Data(), near: databaseURL)
        } catch {
            return .failure("Could not create file-backed child I/O: \(error.localizedDescription)")
        }

        let process = Process()
        process.executableURL = executableURL
        if let feedEvent = Self.codexFeedEvent(from: subcommand) {
            process.arguments = [
                "--socket", socketPath,
                "hooks", "feed", "--source", agent, "--event", feedEvent,
            ]
        } else if Self.isCodexLifecycleSubcommand(subcommand) {
            process.arguments = [
                "--socket", socketPath,
                "hooks", agent, subcommand,
            ]
        } else {
            return .failure("Stored hook delivery target is unsupported.")
        }
        let ambientEnvironment = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["HOME", "LANG", "LC_ALL", "LC_CTYPE", "LOGNAME", "PATH", "SHELL", "TMPDIR", "USER"] {
            if let value = ambientEnvironment[key] {
                environment[key] = value
            }
        }
        environment.merge(eventEnvironment, uniquingKeysWith: { _, eventValue in eventValue })
        environment.merge(
            ephemeralEnvironmentStore.environment(for: deliveryID),
            uniquingKeysWith: { _, ephemeralValue in ephemeralValue }
        )
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLED_CLI_PATH"] = executableURL.path
        environment["CMUX_AGENT_HOOK_DELIVERY_ID"] = deliveryID
        environment["CMUX_AGENT_HOOK_DELIVERY_PROCESS_GROUP"] = "1"
        environment.removeValue(forKey: "CMUX_SOCKET")
        process.environment = environment
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorOutput

        let terminations = AsyncStream<Int32> { continuation in
            process.terminationHandler = { terminatedProcess in
                continuation.yield(terminatedProcess.terminationStatus)
                continuation.finish()
            }
        }
        let processGroupDeadline = Date().timeIntervalSinceReferenceDate + lingeringProcessGroupTimeout
        do {
            try process.run()
            // The bundled CLI also calls setpgid before dispatch. This parent-
            // side attempt closes the spawn-to-main race when the kernel still
            // permits the parent to establish the child's group.
            _ = Darwin.setpgid(process.processIdentifier, process.processIdentifier)
        } catch {
            process.terminationHandler = nil
            return .failure("Could not launch bundled cmux CLI: \(error.localizedDescription)")
        }

        let outcome = await waitForExitOrTimeout(process: process, terminations: terminations)
        process.terminationHandler = nil
        let stderr = Self.readErrorOutput(errorOutput)
        let lingeringProcessGroup: ProcessGroupPermit? = {
            let processGroupID = process.processIdentifier
            guard Self.processGroupExists(processGroupID) else { return nil }
            return ProcessGroupPermit(
                processGroupID: processGroupID,
                deadline: processGroupDeadline
            )
        }()
        if outcome.cancelled {
            return DeliveryAttemptResult(
                succeeded: false,
                error: "Bundled cmux CLI delivery was cancelled.\(stderr)",
                lingeringProcessGroup: lingeringProcessGroup
            )
        }
        if outcome.timedOut {
            return DeliveryAttemptResult(
                succeeded: false,
                error: "Bundled cmux CLI exceeded \(processTimeout)s.\(stderr)",
                lingeringProcessGroup: lingeringProcessGroup
            )
        }
        guard outcome.status == 0 else {
            return DeliveryAttemptResult(
                succeeded: false,
                error: "Bundled cmux CLI exited with status \(outcome.status).\(stderr)",
                lingeringProcessGroup: lingeringProcessGroup
            )
        }
        return DeliveryAttemptResult(
            succeeded: true,
            error: nil,
            lingeringProcessGroup: lingeringProcessGroup
        )
    }

    private nonisolated static func codexFeedEvent(from subcommand: String) -> String? {
        guard subcommand.hasPrefix("feed:"), supportedSubcommand(subcommand) else { return nil }
        return String(subcommand.dropFirst("feed:".count))
    }

    private nonisolated static func isCodexLifecycleSubcommand(_ subcommand: String) -> Bool {
        !subcommand.hasPrefix("feed:") && supportedSubcommand(subcommand)
    }

    private nonisolated static func supportedSubcommand(_ subcommand: String) -> Bool {
        AgentHookDeliveryEvent.supportedSubcommands.contains(subcommand)
    }

    private func waitForExitOrTimeout(
        process: Process,
        terminations: AsyncStream<Int32>
    ) async -> (status: Int32, timedOut: Bool, cancelled: Bool) {
        await withTaskGroup(of: DeliveryProcessRace.self) { group in
            group.addTask {
                for await status in terminations {
                    return .exited(status)
                }
                return Task.isCancelled ? .cancelled : .exited(-1)
            }
            let timeout = processTimeout
            group.addTask {
                do {
                    // This is the child deadline itself, not a polling sleep.
                    try await ContinuousClock().sleep(for: .milliseconds(Int64(timeout * 1_000)))
                    return .deadline
                } catch {
                    return .cancelled
                }
            }

            guard let firstResult = await group.next() else {
                return (-1, false, Task.isCancelled)
            }
            if case .exited(let status) = firstResult {
                group.cancelAll()
                return (status, false, false)
            }

            let wasCancelled: Bool
            switch firstResult {
            case .cancelled:
                wasCancelled = true
            case .deadline:
                wasCancelled = false
            case .exited:
                wasCancelled = false
            }
            let processID = process.processIdentifier
            let processGroupID = Self.ownedProcessGroupID(processID: processID)
            if let processGroupID {
                _ = Darwin.kill(-processGroupID, SIGTERM)
            } else if process.isRunning {
                process.terminate()
            }
            if !wasCancelled {
                // A short grace period lets the child clean up before SIGKILL.
                try? await ContinuousClock().sleep(for: .milliseconds(Int64(terminationGrace * 1_000)))
            }
            if let processGroupID {
                if Self.processGroupExists(processGroupID) {
                    _ = Darwin.kill(-processGroupID, SIGKILL)
                }
            } else if process.isRunning {
                _ = Darwin.kill(processID, SIGKILL)
            }
            process.waitUntilExit()
            group.cancelAll()
            if let processGroupID {
                let groupExitTimeout = max(0.01, terminationGrace)
                await Task.detached {
                    Self.waitForProcessGroupExit(
                        processGroupID,
                        timeout: groupExitTimeout
                    )
                }.value
            }
            return (process.terminationStatus, !wasCancelled, wasCancelled)
        }
    }

    private nonisolated static func ownedProcessGroupID(processID: pid_t) -> pid_t? {
        let processGroupID = Darwin.getpgid(processID)
        return processGroupID == processID ? processGroupID : nil
    }

    private nonisolated static func processGroupExists(_ processGroupID: pid_t) -> Bool {
        if Darwin.kill(-processGroupID, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private nonisolated static func monitorProcessGroup(
        _ permit: ProcessGroupPermit,
        terminationGrace: TimeInterval
    ) async {
        while processGroupExists(permit.processGroupID) {
            if Task.isCancelled {
                await terminateProcessGroup(
                    permit.processGroupID,
                    terminationGrace: terminationGrace,
                    allowGrace: false
                )
                return
            }

            let remaining = permit.deadline - Date().timeIntervalSinceReferenceDate
            if remaining <= 0 {
                await terminateProcessGroup(
                    permit.processGroupID,
                    terminationGrace: terminationGrace,
                    allowGrace: true
                )
                return
            }
            let interval = min(0.025, remaining)
            do {
                try await ContinuousClock().sleep(
                    for: .milliseconds(max(1, Int64(interval * 1_000)))
                )
            } catch {
                await terminateProcessGroup(
                    permit.processGroupID,
                    terminationGrace: terminationGrace,
                    allowGrace: false
                )
                return
            }
        }
    }

    private nonisolated static func terminateProcessGroup(
        _ processGroupID: pid_t,
        terminationGrace: TimeInterval,
        allowGrace: Bool
    ) async {
        guard processGroupID > 1, processGroupID != Darwin.getpgrp() else { return }
        _ = Darwin.kill(-processGroupID, SIGTERM)
        if allowGrace, processGroupExists(processGroupID) {
            await Task.detached {
                waitForProcessGroupExit(
                    processGroupID,
                    timeout: max(0.01, terminationGrace)
                )
            }.value
        }
        if processGroupExists(processGroupID) {
            _ = Darwin.kill(-processGroupID, SIGKILL)
        }
        await Task.detached {
            waitForProcessGroupExit(
                processGroupID,
                timeout: max(1, terminationGrace * 4)
            )
        }.value
    }

    private nonisolated static func forceKillProcessGroup(_ processGroupID: pid_t) {
        guard processGroupID > 1, processGroupID != Darwin.getpgrp() else { return }
        _ = Darwin.kill(-processGroupID, SIGTERM)
        _ = Darwin.kill(-processGroupID, SIGKILL)
    }

    private nonisolated static func waitForProcessGroupExit(
        _ processGroupID: pid_t,
        timeout: TimeInterval
    ) {
        let deadline = Date().timeIntervalSinceReferenceDate + timeout
        while processGroupExists(processGroupID), Date().timeIntervalSinceReferenceDate < deadline {
            var interval = timespec(tv_sec: 0, tv_nsec: 5 * 1_000 * 1_000)
            var remaining = timespec()
            while Darwin.nanosleep(&interval, &remaining) != 0, errno == EINTR {
                interval = remaining
            }
        }
    }

    private nonisolated static func defaultDatabaseURL() -> URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        let bundleID = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        return appSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("agent-hook-delivery.sqlite3", isDirectory: false)
    }

    private nonisolated static func openDatabase(at url: URL) throws -> OpaquePointer {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var status = sqlite3_open_v2(url.path, &database, flags, nil)
        guard status == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw sqliteFailure(status, operation: "open delivery database")
        }

        sqlite3_busy_timeout(database, 250)
        let setupStatements = [
            "PRAGMA journal_mode = WAL;",
            // WAL + NORMAL commits each event before acknowledgement and
            // survives app-process crashes without forcing one fsync per hook.
            // The database remains consistent after a machine crash, although
            // the OS may lose the last acknowledged transactions. This is still
            // stronger than the previous detached, memory-only delivery path.
            "PRAGMA synchronous = NORMAL;",
            "PRAGMA wal_autocheckpoint = 256;",
            "PRAGMA journal_size_limit = \(maximumWALBytes);",
            // Credential migrations must overwrite removed values rather than
            // leaving them in SQLite free blocks.
            "PRAGMA secure_delete = ON;",
            """
            CREATE TABLE IF NOT EXISTS agent_hook_deliveries (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                delivery_id TEXT NOT NULL UNIQUE,
                ordering_key TEXT NOT NULL,
                content_digest BLOB NOT NULL,
                agent TEXT NOT NULL,
                subcommand TEXT NOT NULL,
                payload BLOB NOT NULL,
                socket_path TEXT NOT NULL,
                environment_json BLOB NOT NULL,
                retained_bytes INTEGER NOT NULL DEFAULT 0,
                accepted_at REAL NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_attempt_at REAL,
                next_attempt_at REAL NOT NULL,
                delivered_at REAL,
                last_error TEXT
            );
            """,
        ]
        for sql in setupStatements {
            status = sqlite3_exec(database, sql, nil, nil, nil)
            guard status == SQLITE_OK else {
                sqlite3_close_v2(database)
                throw sqliteFailure(status, operation: "initialize delivery database")
            }
        }
        if try tableHasColumn("ordering_key", table: "agent_hook_deliveries", database: database) == false {
            status = sqlite3_exec(
                database,
                "ALTER TABLE agent_hook_deliveries ADD COLUMN ordering_key TEXT NOT NULL DEFAULT '';",
                nil,
                nil,
                nil
            )
            guard status == SQLITE_OK else {
                sqlite3_close_v2(database)
                throw sqliteFailure(status, operation: "add delivery ordering key")
            }
        }
        if try tableHasColumn("retained_bytes", table: "agent_hook_deliveries", database: database) == false {
            status = sqlite3_exec(
                database,
                "ALTER TABLE agent_hook_deliveries ADD COLUMN retained_bytes INTEGER NOT NULL DEFAULT 0;",
                nil,
                nil,
                nil
            )
            guard status == SQLITE_OK else {
                sqlite3_close_v2(database)
                throw sqliteFailure(status, operation: "add delivery retained-byte accounting")
            }
        }
        do {
            let scrubbedCredentialRows = try scrubPersistedEnvironments(database: database)
            try backfillLegacyOrderingKeys(database: database)
            if scrubbedCredentialRows {
                try compactAfterCredentialScrub(database: database)
            }
            try initializeResourceBudget(database: database)
            try configurePhysicalStorageBudget(database: database)
        } catch {
            sqlite3_close_v2(database)
            throw error
        }
        let indexStatements = [
            """
            CREATE INDEX IF NOT EXISTS agent_hook_deliveries_due
            ON agent_hook_deliveries (delivered_at, next_attempt_at, sequence);
            """,
            """
            CREATE INDEX IF NOT EXISTS agent_hook_deliveries_ordering
            ON agent_hook_deliveries (ordering_key, delivered_at, sequence);
            """,
            """
            CREATE INDEX IF NOT EXISTS agent_hook_deliveries_receipts
            ON agent_hook_deliveries (delivered_at, sequence);
            """,
        ]
        for sql in indexStatements {
            status = sqlite3_exec(database, sql, nil, nil, nil)
            guard status == SQLITE_OK else {
                sqlite3_close_v2(database)
                throw sqliteFailure(status, operation: "initialize delivery indexes")
            }
        }
        Darwin.chmod(url.path, 0o600)
        return database
    }

    private nonisolated static func tableHasColumn(
        _ column: String,
        table: String,
        database: OpaquePointer
    ) throws -> Bool {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil)
        guard status == SQLITE_OK else {
            throw sqliteFailure(status, operation: "inspect delivery schema")
        }
        defer { sqlite3_finalize(statement) }
        var stepStatus = sqlite3_step(statement)
        while stepStatus == SQLITE_ROW {
            if columnText(statement, at: 1) == column {
                return true
            }
            stepStatus = sqlite3_step(statement)
        }
        guard stepStatus == SQLITE_DONE else {
            throw sqliteFailure(stepStatus, operation: "read delivery schema")
        }
        return false
    }

    private nonisolated static func initializeResourceBudget(
        database: OpaquePointer
    ) throws {
        let statements = [
            """
            UPDATE agent_hook_deliveries
            SET retained_bytes =
                length(delivery_id) + length(ordering_key) + length(content_digest)
                + length(agent) + length(subcommand) + length(payload)
                + length(socket_path) + length(environment_json)
            WHERE delivered_at IS NULL;
            """,
            """
            DELETE FROM agent_hook_deliveries
            WHERE sequence IN (
                SELECT sequence
                FROM agent_hook_deliveries
                WHERE delivered_at IS NOT NULL
                ORDER BY delivered_at DESC, sequence DESC
                LIMIT -1 OFFSET \(maximumDeliveredReceipts)
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS agent_hook_delivery_quota (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                pending_count INTEGER NOT NULL CHECK (pending_count >= 0),
                pending_bytes INTEGER NOT NULL CHECK (pending_bytes >= 0)
            );
            """,
            """
            INSERT INTO agent_hook_delivery_quota (singleton, pending_count, pending_bytes)
            VALUES (1, 0, 0)
            ON CONFLICT(singleton) DO NOTHING;
            """,
            """
            UPDATE agent_hook_delivery_quota
            SET pending_count = (
                    SELECT count(*) FROM agent_hook_deliveries WHERE delivered_at IS NULL
                ),
                pending_bytes = COALESCE((
                    SELECT sum(retained_bytes)
                    FROM agent_hook_deliveries
                    WHERE delivered_at IS NULL
                ), 0)
            WHERE singleton = 1;
            """,
            "DROP TRIGGER IF EXISTS agent_hook_delivery_admission_limit;",
            "DROP TRIGGER IF EXISTS agent_hook_delivery_admission_add;",
            "DROP TRIGGER IF EXISTS agent_hook_delivery_pending_remove;",
            "DROP TRIGGER IF EXISTS agent_hook_delivery_complete;",
            """
            CREATE TRIGGER agent_hook_delivery_admission_limit
            BEFORE INSERT ON agent_hook_deliveries
            WHEN NEW.delivered_at IS NULL AND (
                NEW.retained_bytes < 0
                OR (SELECT pending_count FROM agent_hook_delivery_quota WHERE singleton = 1)
                    >= \(maximumPendingDeliveries)
                OR NEW.retained_bytes > \(maximumPendingBytes)
                OR (SELECT pending_bytes FROM agent_hook_delivery_quota WHERE singleton = 1)
                    > \(maximumPendingBytes) - NEW.retained_bytes
            )
            BEGIN
                SELECT RAISE(ABORT, 'agent_hook_queue_capacity');
            END;
            """,
            """
            CREATE TRIGGER agent_hook_delivery_admission_add
            AFTER INSERT ON agent_hook_deliveries
            WHEN NEW.delivered_at IS NULL
            BEGIN
                UPDATE agent_hook_delivery_quota
                SET pending_count = pending_count + 1,
                    pending_bytes = pending_bytes + NEW.retained_bytes
                WHERE singleton = 1;
            END;
            """,
            """
            CREATE TRIGGER agent_hook_delivery_pending_remove
            AFTER DELETE ON agent_hook_deliveries
            WHEN OLD.delivered_at IS NULL
            BEGIN
                UPDATE agent_hook_delivery_quota
                SET pending_count = pending_count - 1,
                    pending_bytes = pending_bytes - OLD.retained_bytes
                WHERE singleton = 1;
            END;
            """,
            """
            CREATE TRIGGER agent_hook_delivery_complete
            AFTER UPDATE OF delivered_at ON agent_hook_deliveries
            WHEN OLD.delivered_at IS NULL AND NEW.delivered_at IS NOT NULL
            BEGIN
                UPDATE agent_hook_delivery_quota
                SET pending_count = pending_count - 1,
                    pending_bytes = pending_bytes - OLD.retained_bytes
                WHERE singleton = 1;
                DELETE FROM agent_hook_deliveries
                WHERE sequence IN (
                    SELECT sequence
                    FROM agent_hook_deliveries
                    WHERE delivered_at IS NOT NULL
                    ORDER BY delivered_at DESC, sequence DESC
                    LIMIT -1 OFFSET \(maximumDeliveredReceipts)
                );
            END;
            """,
        ]
        for statement in statements {
            let status = sqlite3_exec(database, statement, nil, nil, nil)
            guard status == SQLITE_OK else {
                throw sqliteFailure(status, operation: "initialize delivery resource budget")
            }
        }
    }

    private nonisolated static func configurePhysicalStorageBudget(
        database: OpaquePointer
    ) throws {
        let pageSize = try pragmaInteger("page_size", database: database)
        guard pageSize > 0 else {
            throw failure("SQLite reported an invalid page size.", code: 14)
        }
        let maximumPages = max(1, maximumPhysicalDatabaseBytes / pageSize)
        var status = sqlite3_exec(
            database,
            "PRAGMA max_page_count = \(maximumPages);",
            nil,
            nil,
            nil
        )
        guard status == SQLITE_OK else {
            throw sqliteFailure(status, operation: "set delivery database page limit")
        }
        let appliedMaximum = try pragmaInteger("max_page_count", database: database)
        guard appliedMaximum <= maximumPages else {
            throw failure(
                "Existing delivery database exceeds its physical page budget.",
                code: 15
            )
        }
        // One writer and 256-page auto-checkpoints bound normal WAL growth;
        // truncate startup residue before accepting any new hook.
        status = sqlite3_exec(
            database,
            "PRAGMA wal_checkpoint(TRUNCATE);",
            nil,
            nil,
            nil
        )
        guard status == SQLITE_OK else {
            throw sqliteFailure(status, operation: "truncate delivery WAL")
        }
    }

    private nonisolated static func pragmaInteger(
        _ name: String,
        database: OpaquePointer
    ) throws -> Int {
        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(
            database,
            "PRAGMA \(name);",
            -1,
            &statement,
            nil
        )
        guard prepareStatus == SQLITE_OK, let statement else {
            throw sqliteFailure(prepareStatus, operation: "prepare SQLite pragma \(name)")
        }
        defer { sqlite3_finalize(statement) }
        let stepStatus = sqlite3_step(statement)
        guard stepStatus == SQLITE_ROW else {
            throw sqliteFailure(stepStatus, operation: "read SQLite pragma \(name)")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private nonisolated static func scrubPersistedEnvironments(
        database: OpaquePointer
    ) throws -> Bool {
        var status = sqlite3_exec(database, "BEGIN IMMEDIATE;", nil, nil, nil)
        guard status == SQLITE_OK else {
            throw sqliteFailure(status, operation: "begin delivery credential scrub")
        }
        do {
            var rows: [(
                sequence: Int64,
                agent: String,
                subcommand: String,
                payload: Data,
                environment: Data,
                isPending: Bool,
                contentDigest: Data
            )] = []
            do {
                var statement: OpaquePointer?
                status = sqlite3_prepare_v2(
                    database,
                    """
                    SELECT sequence, agent, subcommand, payload, environment_json,
                           delivered_at IS NULL, content_digest
                    FROM agent_hook_deliveries
                    WHERE environment_json != X'7B7D'
                    ORDER BY sequence ASC;
                    """,
                    -1,
                    &statement,
                    nil
                )
                guard status == SQLITE_OK else {
                    throw sqliteFailure(status, operation: "prepare delivery credential scrub")
                }
                defer { sqlite3_finalize(statement) }
                while true {
                    status = sqlite3_step(statement)
                    if status == SQLITE_DONE { break }
                    guard status == SQLITE_ROW,
                          let agent = columnText(statement, at: 1),
                          let subcommand = columnText(statement, at: 2),
                          let payload = columnData(statement, at: 3),
                          let environmentData = columnData(statement, at: 4),
                          let contentDigest = columnData(statement, at: 6) else {
                        throw sqliteFailure(status, operation: "read delivery credential scrub")
                    }
                    rows.append((
                        sequence: sqlite3_column_int64(statement, 0),
                        agent: agent,
                        subcommand: subcommand,
                        payload: payload,
                        environment: environmentData,
                        isPending: sqlite3_column_int(statement, 5) != 0,
                        contentDigest: contentDigest
                    ))
                }
            }

            let policy = AgentHookTransportEnvironmentPolicy()
            var scrubbedRows: [(sequence: Int64, environment: Data, contentDigest: Data)] = []
            scrubbedRows.reserveCapacity(rows.count)
            for row in rows {
                let decoded = (try? JSONSerialization.jsonObject(with: row.environment)) as? [String: String]
                let scrubbed = policy.durableEnvironmentForPersistence(from: decoded ?? [:])
                let scrubbedData = try JSONSerialization.data(withJSONObject: scrubbed, options: [.sortedKeys])
                let scrubbedDigest = row.isPending
                    ? AgentHookDeliveryEvent.contentDigest(
                        agent: row.agent,
                        subcommand: row.subcommand,
                        payload: row.payload,
                        environment: scrubbed
                    )
                    : row.contentDigest
                if scrubbedData != row.environment || scrubbedDigest != row.contentDigest {
                    scrubbedRows.append((
                        sequence: row.sequence,
                        environment: scrubbedData,
                        contentDigest: scrubbedDigest
                    ))
                }
            }

            if !scrubbedRows.isEmpty {
                var update: OpaquePointer?
                status = sqlite3_prepare_v2(
                    database,
                    """
                    UPDATE agent_hook_deliveries
                    SET environment_json = ?, content_digest = ?
                    WHERE sequence = ?;
                    """,
                    -1,
                    &update,
                    nil
                )
                guard status == SQLITE_OK else {
                    throw sqliteFailure(status, operation: "prepare scrubbed delivery environment update")
                }
                defer { sqlite3_finalize(update) }
                for row in scrubbedRows {
                    sqlite3_reset(update)
                    sqlite3_clear_bindings(update)
                    status = bind(row.environment, to: update, at: 1)
                    guard status == SQLITE_OK else {
                        throw sqliteFailure(status, operation: "bind scrubbed delivery environment")
                    }
                    status = bind(row.contentDigest, to: update, at: 2)
                    guard status == SQLITE_OK else {
                        throw sqliteFailure(status, operation: "bind scrubbed delivery digest")
                    }
                    status = sqlite3_bind_int64(update, 3, row.sequence)
                    guard status == SQLITE_OK else {
                        throw sqliteFailure(status, operation: "bind scrubbed delivery sequence")
                    }
                    status = sqlite3_step(update)
                    guard status == SQLITE_DONE else {
                        throw sqliteFailure(status, operation: "update scrubbed delivery environment")
                    }
                }
            }

            status = sqlite3_exec(database, "COMMIT;", nil, nil, nil)
            guard status == SQLITE_OK else {
                throw sqliteFailure(status, operation: "commit delivery credential scrub")
            }
            return !scrubbedRows.isEmpty
        } catch {
            sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    private nonisolated static func compactAfterCredentialScrub(
        database: OpaquePointer
    ) throws {
        var logFrames: Int32 = 0
        var checkpointedFrames: Int32 = 0
        var status = sqlite3_wal_checkpoint_v2(
            database,
            nil,
            SQLITE_CHECKPOINT_TRUNCATE,
            &logFrames,
            &checkpointedFrames
        )
        guard status == SQLITE_OK else {
            throw sqliteFailure(status, operation: "checkpoint scrubbed delivery database")
        }
        status = sqlite3_exec(database, "VACUUM;", nil, nil, nil)
        guard status == SQLITE_OK else {
            throw sqliteFailure(status, operation: "compact scrubbed delivery database")
        }
        status = sqlite3_wal_checkpoint_v2(
            database,
            nil,
            SQLITE_CHECKPOINT_TRUNCATE,
            &logFrames,
            &checkpointedFrames
        )
        guard status == SQLITE_OK else {
            throw sqliteFailure(status, operation: "truncate scrubbed delivery WAL")
        }
    }

    private nonisolated static func backfillLegacyOrderingKeys(database: OpaquePointer) throws {
        var status = sqlite3_exec(database, "BEGIN IMMEDIATE;", nil, nil, nil)
        guard status == SQLITE_OK else {
            throw sqliteFailure(status, operation: "begin delivery ordering backfill")
        }
        do {
            var rows: [(sequence: Int64, orderingKey: String)] = []
            do {
                var statement: OpaquePointer?
                status = sqlite3_prepare_v2(
                    database,
                    """
                    SELECT sequence, delivery_id, socket_path, environment_json
                    FROM agent_hook_deliveries
                    WHERE delivered_at IS NULL AND ordering_key = ''
                    ORDER BY sequence ASC;
                    """,
                    -1,
                    &statement,
                    nil
                )
                guard status == SQLITE_OK else {
                    throw sqliteFailure(status, operation: "prepare delivery ordering backfill")
                }
                defer { sqlite3_finalize(statement) }
                while true {
                    status = sqlite3_step(statement)
                    if status == SQLITE_DONE { break }
                    guard status == SQLITE_ROW else {
                        throw sqliteFailure(status, operation: "read delivery ordering backfill")
                    }
                    guard let deliveryID = columnText(statement, at: 1),
                          let socketPath = columnText(statement, at: 2),
                          let environmentData = columnData(statement, at: 3),
                          let environment = (try? JSONSerialization.jsonObject(with: environmentData)) as? [String: String] else {
                        // Keep malformed legacy rows on the empty-key global
                        // barrier so they drain conservatively before new work.
                        continue
                    }
                    rows.append((
                        sequence: sqlite3_column_int64(statement, 0),
                        orderingKey: AgentHookDeliveryEvent.orderingKey(
                            deliveryID: deliveryID,
                            socketPath: socketPath,
                            environment: environment
                        )
                    ))
                }
            }

            var update: OpaquePointer?
            status = sqlite3_prepare_v2(
                database,
                "UPDATE agent_hook_deliveries SET ordering_key = ? WHERE sequence = ? AND ordering_key = '';",
                -1,
                &update,
                nil
            )
            guard status == SQLITE_OK else {
                throw sqliteFailure(status, operation: "prepare delivery ordering update")
            }
            defer { sqlite3_finalize(update) }
            for row in rows {
                sqlite3_reset(update)
                sqlite3_clear_bindings(update)
                status = bind(row.orderingKey, to: update, at: 1)
                guard status == SQLITE_OK else {
                    throw sqliteFailure(status, operation: "bind delivery ordering key")
                }
                status = sqlite3_bind_int64(update, 2, row.sequence)
                guard status == SQLITE_OK else {
                    throw sqliteFailure(status, operation: "bind delivery ordering sequence")
                }
                status = sqlite3_step(update)
                guard status == SQLITE_DONE else {
                    throw sqliteFailure(status, operation: "update delivery ordering key")
                }
            }
            status = sqlite3_exec(database, "COMMIT;", nil, nil, nil)
            guard status == SQLITE_OK else {
                throw sqliteFailure(status, operation: "commit delivery ordering backfill")
            }
        } catch {
            sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    private nonisolated static func storedDigest(
        for deliveryID: String,
        database: OpaquePointer
    ) throws -> Data? {
        var statement: OpaquePointer?
        var status = sqlite3_prepare_v2(
            database,
            "SELECT content_digest FROM agent_hook_deliveries WHERE delivery_id = ? LIMIT 1;",
            -1,
            &statement,
            nil
        )
        guard status == SQLITE_OK else {
            throw sqliteFailure(status, operation: "prepare duplicate check")
        }
        defer { sqlite3_finalize(statement) }
        status = bind(deliveryID, to: statement, at: 1)
        guard status == SQLITE_OK else { throw sqliteFailure(status, operation: "bind duplicate check") }
        status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw sqliteFailure(status, operation: "read duplicate check") }
        return columnData(statement, at: 0)
    }

    private nonisolated static func storedDeliveryIsPending(
        for deliveryID: String,
        database: OpaquePointer
    ) throws -> Bool {
        var statement: OpaquePointer?
        var status = sqlite3_prepare_v2(
            database,
            "SELECT delivered_at IS NULL FROM agent_hook_deliveries WHERE delivery_id = ? LIMIT 1;",
            -1,
            &statement,
            nil
        )
        guard status == SQLITE_OK else {
            throw sqliteFailure(status, operation: "prepare pending delivery check")
        }
        defer { sqlite3_finalize(statement) }
        status = bind(deliveryID, to: statement, at: 1)
        guard status == SQLITE_OK else {
            throw sqliteFailure(status, operation: "bind pending delivery check")
        }
        status = sqlite3_step(statement)
        guard status == SQLITE_ROW else {
            throw sqliteFailure(status, operation: "read pending delivery check")
        }
        return sqlite3_column_int(statement, 0) != 0
    }

    private nonisolated static func anonymousFile(containing data: Data, near databaseURL: URL) throws -> FileHandle {
        let directory = databaseURL.deletingLastPathComponent()
        var template = Array(directory.appendingPathComponent("agent-hook-io.XXXXXX").path.utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { buffer in
            mkstemp(buffer.baseAddress)
        }
        guard descriptor >= 0 else {
            throw failure("mkstemp failed with errno \(errno).", code: 6)
        }
        Darwin.fchmod(descriptor, 0o600)
        template.withUnsafeBufferPointer { buffer in
            if let baseAddress = buffer.baseAddress {
                Darwin.unlink(baseAddress)
            }
        }

        var writeError: Int32?
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    writeError = errno
                    break
                }
                offset += count
            }
        }
        if let writeError {
            Darwin.close(descriptor)
            throw failure("Writing child I/O file failed with errno \(writeError).", code: 7)
        }
        guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
            let seekError = errno
            Darwin.close(descriptor)
            throw failure("Seeking child I/O file failed with errno \(seekError).", code: 8)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private nonisolated static func readErrorOutput(_ file: FileHandle) -> String {
        do {
            try file.seek(toOffset: 0)
            guard let data = try file.read(upToCount: 4_096), !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else {
                return ""
            }
            return " stderr: \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
        } catch {
            return ""
        }
    }

    private nonisolated static func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) -> Int32 {
        value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, sqliteTransient)
        }
    }

    private nonisolated static func bind(_ value: Data, to statement: OpaquePointer?, at index: Int32) -> Int32 {
        if value.isEmpty {
            return sqlite3_bind_zeroblob(statement, index, 0)
        }
        return value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
    }

    private nonisolated static func columnText(_ statement: OpaquePointer?, at index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private nonisolated static func columnData(_ statement: OpaquePointer?, at index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0 else { return Data() }
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private nonisolated static func sqliteFailure(_ status: Int32, operation: String) -> NSError {
        let message = sqlite3_errstr(status).map(String.init(cString:)) ?? "unknown SQLite error"
        return failure("Could not \(operation): \(message) (\(status)).", code: Int(status))
    }

    private nonisolated static func failure(_ message: String, code: Int) -> NSError {
        NSError(
            domain: "com.cmuxterm.agent-hook-delivery",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
