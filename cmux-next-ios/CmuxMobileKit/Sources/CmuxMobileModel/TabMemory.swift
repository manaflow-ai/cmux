import Foundation

/// Where the last-used tab per workspace is kept on this device. The app uses
/// `UserDefaults`; tests use an in-memory store.
public final class TabMemory: @unchecked Sendable {
    private let lock = NSLock()
    private let read: () -> [String: String]
    private let write: ([String: String]) -> Void

    public init(load: @escaping () -> [String: String], save: @escaping ([String: String]) -> Void) {
        read = load
        write = save
    }

    public func load() -> [String: String] { lock.withLock { read() } }
    public func save(_ map: [String: String]) { lock.withLock { write(map) } }

    /// Backed by `defaults` under `key` (a plain string dictionary).
    public convenience init(defaults: UserDefaults, key: String = "cmuxMobile.lastTabByWorkspace") {
        self.init(
            load: { defaults.dictionary(forKey: key) as? [String: String] ?? [:] },
            save: { defaults.set($0, forKey: key) }
        )
    }

    /// The app's store: survives relaunches.
    public static let standard = TabMemory(defaults: .standard)

    /// A fresh store that forgets everything at deinit.
    public static func inMemory(_ initial: [String: String] = [:]) -> TabMemory {
        var map = initial
        return TabMemory(load: { map }, save: { map = $0 })
    }
}
