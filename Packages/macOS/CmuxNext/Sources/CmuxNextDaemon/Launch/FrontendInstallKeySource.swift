import CmuxNextWakeups
import Foundation

/// The install key a launcher hands its daemon and proves in `client-hello`: none, a fixed key (tests, a
/// harness), or the app's own, read once off the thread that builds the launcher.
///
/// The app builds its launchers on the main thread (`main`'s prestart, the Chief owner's start), and the key
/// needs the signing team (a securityd call) and then the key file. Both run on ``BackgroundWork`` lanes, the
/// team on the system lane and the file on the files lane; the async readers (`server ensure`, the handshake,
/// the install-key handoff) await ``key()``. Chrome keeps such reads off the UI thread the same way: the
/// blocking work is posted with `MayBlock` and its result reaches the reader as a reply
/// (base/task/thread_pool.h, `PostTaskAndReplyWithResult`).
public struct FrontendInstallKeySource: Sendable, Hashable {
    private enum Storage: Sendable, Hashable {
        case fixed(FrontendInstallKey?)
        case read(FrontendInstallKeyRead)
    }

    private let storage: Storage

    private init(_ storage: Storage) {
        self.storage = storage
    }

    /// No key: the app proves nothing (a signed build proves itself by its code signature).
    public static let noKey = FrontendInstallKeySource(.fixed(nil))

    /// `key`, known now.
    public static func fixed(_ key: FrontendInstallKey?) -> FrontendInstallKeySource {
        FrontendInstallKeySource(.fixed(key))
    }

    /// The key `stores` picks for `stateDirectory`, read once on `work`'s lanes; the read starts now.
    static func reading(_ stores: FrontendInstallKeyStores, stateDirectory: URL, on work: BackgroundWork) -> FrontendInstallKeySource {
        FrontendInstallKeySource(.read(FrontendInstallKeyRead(stores: stores, stateDirectory: stateDirectory, work: work)))
    }

    /// The key, nil when there is none or it could not be read. Awaits the lanes' read the first time; never
    /// blocks the caller's thread.
    public func key() async -> FrontendInstallKey? {
        switch storage {
        case .fixed(let key): key
        case .read(let read): await read.key()
        }
    }
}

/// One read of the app's install key on a ``BackgroundWork``'s lanes, started when it is made. Equal only to
/// itself: two reads of one state directory are two launchers.
final class FrontendInstallKeyRead: Sendable, Hashable {
    private let read: Task<FrontendInstallKey?, any Error>

    init(stores: FrontendInstallKeyStores, stateDirectory: URL, work: BackgroundWork) {
        // task-owner: one read per launcher, two lane items (securityd, then one small file); quit cancels it
        read = work.task(.userBlocking) { () async throws -> FrontendInstallKey? in
            let signed = try await work.run(.userBlocking, mayBlock: .system) { stores.isSigned() }
            if signed { return nil }
            return try await work.run(.userBlocking, mayBlock: .files) {
                FileFrontendInstallKeyStore(file: FrontendInstallKeyStores.keyFile(in: stateDirectory)).loadOrCreate()
            }
        }
    }

    /// The key; nil when the build is signed, the file cannot be used, or quit dropped the read.
    func key() async -> FrontendInstallKey? {
        try? await read.value
    }

    static func == (lhs: FrontendInstallKeyRead, rhs: FrontendInstallKeyRead) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
