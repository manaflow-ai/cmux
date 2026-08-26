import Foundation

/// Pins a resumed Hermes process to the profile home that owns its session database.
///
/// A root `HERMES_HOME` is not sufficient by itself because Hermes may redirect it
/// through a sticky `active_profile`. The default profile therefore also requires an
/// explicit `--profile default`, while a named `profiles/<name>` home is authoritative.
///
/// ```swift
/// let pin = HermesAgentResumeProfilePin(
///     hermesHome: nil,
///     homeDirectory: "/Users/example"
/// )
/// let arguments = pin.applying(to: ["hermes", "--resume", "session-id"])
/// ```
public struct HermesAgentResumeProfilePin: Equatable, Sendable {
    /// The exact `HERMES_HOME` that owns the resumed session database.
    public let hermesHome: String

    /// Profile-selection arguments required in addition to ``hermesHome``.
    public let requiredProfileArguments: [String]

    /// Resolves the deterministic profile identity for a Hermes resume.
    ///
    /// - Parameters:
    ///   - hermesHome: The captured or indexed Hermes home, or `nil` for the user's default store.
    ///   - homeDirectory: The user home used to resolve the default store and `~` paths.
    public init(hermesHome: String?, homeDirectory: String) {
        var environment = ["HOME": homeDirectory]
        if let hermesHome = Self.normalized(hermesHome) {
            environment["HERMES_HOME"] = hermesHome
        }
        let resolvedHome = HermesAgentSessionResolver.hermesHome(env: environment)
        self.hermesHome = (resolvedHome as NSString).standardizingPath

        let parent = (self.hermesHome as NSString).deletingLastPathComponent
        self.requiredProfileArguments = (parent as NSString).lastPathComponent == "profiles"
            ? []
            : ["--profile", "default"]
    }

    /// Adds the required profile selector unless the invocation already has one.
    ///
    /// - Parameter arguments: Hermes argv including the executable at index zero.
    /// - Returns: Arguments pinned to the owning profile without duplicating an explicit selector.
    public func applying(to arguments: [String]) -> [String] {
        guard !arguments.isEmpty,
              explicitProfileArguments(in: arguments).isEmpty,
              !requiredProfileArguments.isEmpty else {
            return arguments
        }
        var pinned = arguments
        pinned.insert(contentsOf: requiredProfileArguments, at: 1)
        return pinned
    }

    /// Returns the profile selector that should prefix a related Hermes command.
    ///
    /// - Parameter arguments: The already-pinned resume argv.
    /// - Returns: An explicit captured selector, or the selector required by this pin.
    public func profileArguments(in arguments: [String]) -> [String] {
        let explicit = explicitProfileArguments(in: arguments)
        return explicit.isEmpty ? requiredProfileArguments : explicit
    }

    private func explicitProfileArguments(in arguments: [String]) -> [String] {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--profile" || argument == "-p" {
                let valueIndex = arguments.index(after: index)
                guard valueIndex < arguments.endIndex else { return [argument] }
                return [argument, arguments[valueIndex]]
            }
            if argument.hasPrefix("--profile=") || argument.hasPrefix("-p=") {
                return [argument]
            }
            index = arguments.index(after: index)
        }
        return []
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
