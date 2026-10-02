import Foundation

/// cmux-owned Code Puppy callback plugin and ownership registry transformations.
public enum CodePuppyPlugin {
    public static let pluginName = "cmux-session"
    public static let registryFileName = "external_plugins.json"

    public static func render(cmuxExecutablePath: String, socketPath: String?) -> String {
        ""
    }

    public static func installing(registryData: Data?, pluginPath: String) throws -> Data {
        registryData ?? Data("{}".utf8)
    }

    public static func uninstalling(registryData: Data?, pluginPath: String) throws -> Data? {
        registryData
    }
}
