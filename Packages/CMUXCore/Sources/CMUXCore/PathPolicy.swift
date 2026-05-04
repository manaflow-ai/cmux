import Foundation

public enum CMUXPlatform: String, Codable, Sendable {
    case linux
    case macOS = "macos"
}

public struct CMUXPathEnvironment: Equatable, Sendable {
    public let homeDirectory: String
    public let xdgConfigHome: String?
    public let xdgStateHome: String?
    public let xdgRuntimeDirectory: String?
    public let macOSApplicationSupportDirectory: String?
    public let temporaryDirectory: String

    public init(
        homeDirectory: String,
        xdgConfigHome: String? = nil,
        xdgStateHome: String? = nil,
        xdgRuntimeDirectory: String? = nil,
        macOSApplicationSupportDirectory: String? = nil,
        temporaryDirectory: String = "/tmp"
    ) {
        self.homeDirectory = homeDirectory
        self.xdgConfigHome = xdgConfigHome
        self.xdgStateHome = xdgStateHome
        self.xdgRuntimeDirectory = xdgRuntimeDirectory
        self.macOSApplicationSupportDirectory = macOSApplicationSupportDirectory
        self.temporaryDirectory = temporaryDirectory
    }
}

public struct CMUXResolvedPaths: Equatable, Sendable {
    public let configDirectory: String
    public let stateDirectory: String
    public let socketDirectory: String

    public init(configDirectory: String, stateDirectory: String, socketDirectory: String) {
        self.configDirectory = configDirectory
        self.stateDirectory = stateDirectory
        self.socketDirectory = socketDirectory
    }

    public var socketFilePath: String {
        CMUXPathPolicy.join(socketDirectory, "cmux.sock")
    }
}

public enum CMUXPathPolicyError: Error, Equatable, Sendable {
    case emptyHomeDirectory
}

public enum CMUXPathPolicy {
    public static func resolve(
        platform: CMUXPlatform,
        environment: CMUXPathEnvironment
    ) throws -> CMUXResolvedPaths {
        guard !environment.homeDirectory.isEmpty else {
            throw CMUXPathPolicyError.emptyHomeDirectory
        }

        switch platform {
        case .linux:
            return resolveLinux(environment: environment)
        case .macOS:
            return resolveMacOS(environment: environment)
        }
    }

    private static func resolveLinux(environment: CMUXPathEnvironment) -> CMUXResolvedPaths {
        let configRoot = environment.xdgConfigHome ?? join(environment.homeDirectory, ".config")
        let stateRoot = environment.xdgStateHome ?? join(environment.homeDirectory, ".local", "state")
        let socketRoot = environment.xdgRuntimeDirectory ?? environment.temporaryDirectory

        return CMUXResolvedPaths(
            configDirectory: join(configRoot, "cmux"),
            stateDirectory: join(stateRoot, "cmux"),
            socketDirectory: join(socketRoot, "cmux")
        )
    }

    private static func resolveMacOS(environment: CMUXPathEnvironment) -> CMUXResolvedPaths {
        let appSupportRoot = environment.macOSApplicationSupportDirectory
            ?? join(environment.homeDirectory, "Library", "Application Support")
        let appDirectory = join(appSupportRoot, "cmux")

        return CMUXResolvedPaths(
            configDirectory: appDirectory,
            stateDirectory: appDirectory,
            socketDirectory: appDirectory
        )
    }

    fileprivate static func join(_ parts: String...) -> String {
        parts
            .filter { !$0.isEmpty }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            .joined(separator: "/")
            .withLeadingSlash(parts.first?.hasPrefix("/") == true)
    }
}

private extension String {
    func withLeadingSlash(_ needsLeadingSlash: Bool) -> String {
        needsLeadingSlash ? "/" + self : self
    }
}
