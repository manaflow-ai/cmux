import Foundation

/// The App Group container the app and its notification extensions share
/// (Info.plist `CmuxMobileAppGroup`). Nil in a build without the App Group
/// entitlement (a hand-installed wildcard-signed build): the extension then
/// offers "Open in app" only.
public struct PushAppGroup: Sendable, Equatable {
    public static let infoKey = "CmuxMobileAppGroup"

    public var identifier: String
    public var directory: URL

    public init(identifier: String, directory: URL) {
        self.identifier = identifier
        self.directory = directory
    }

    /// The current bundle's group, when it is configured and entitled.
    public static func current(bundle: Bundle = .main) -> PushAppGroup? {
        PushAppGroupResolver.resolve(.live(bundle: bundle))
    }
}

/// The seam the launch regression tests drive. This is the shipped
/// behavior: the lookup runs on the caller's thread, whatever the build is
/// signed with.
public final class PushAppGroupResolver: @unchecked Sendable { // crash-allow: lock-guarded
    public static let defaultTimeout: Duration = .seconds(2)

    public struct Environment: Sendable {
        public var configuredIdentifier: @Sendable () -> String?
        public var entitledGroups: @Sendable () -> [String]?
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
            return Environment(configuredIdentifier: { identifier }, entitledGroups: { nil },
                               containerURL: { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) })
        }
    }

    private let environment: Environment
    private let lock = NSLock()
    private var result: PushAppGroup??

    public init(environment: Environment) {
        self.environment = environment
    }

    public func start() {
        _ = lookup()
    }

    public func resolved(timeout: Duration = PushAppGroupResolver.defaultTimeout) async -> PushAppGroup? {
        lookup()
    }

    private func lookup() -> PushAppGroup? {
        if let result = lock.withLock({ result }) { return result }
        let group = Self.resolve(environment)
        lock.withLock { result = .some(group) }
        return group
    }

    static func resolve(_ environment: Environment) -> PushAppGroup? {
        guard let id = environment.configuredIdentifier(), !id.isEmpty,
              let url = environment.containerURL(id) else { return nil }
        return PushAppGroup(identifier: id, directory: url)
    }
}
