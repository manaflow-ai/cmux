import Foundation

/// UI-free identity and command-line metadata for first-party right-sidebar
/// modes.
///
/// The macOS app's view registry adds presentation and availability policy on
/// top of this catalog. Keeping the stable identifiers and aliases here lets
/// the standalone `cmux-cli` target validate and document the same command
/// vocabulary without importing AppKit or SwiftUI.
public struct RightSidebarModeCatalog: Equatable, Sendable {
    /// One stable right-sidebar identifier and its accepted CLI spellings.
    public typealias Entry = RightSidebarModeCatalogEntry

    /// The ordered first-party mode vocabulary shared by app and CLI targets.
    public let entries: [Entry]

    /// Creates the built-in right-sidebar command catalog.
    public init() {
        entries = [
            Entry(id: "files", cliArgument: "files"),
            Entry(id: "find", cliArgument: "find"),
            Entry(id: "sessions", cliArgument: "vault", cliAliases: ["sessions"]),
            Entry(id: "feed", cliArgument: "feed"),
            Entry(id: "dock", cliArgument: "dock"),
            Entry(id: "machines", cliArgument: "machines", cliAliases: ["cloud", "vms"]),
            Entry(id: "sourceControl", cliArgument: "source-control", cliAliases: ["sourcecontrol"]),
            Entry(id: "custom-sidebar", cliArgument: "custom", cliAliases: ["custom-sidebar"]),
        ]
    }

    /// Finds an entry by its persisted mode identifier.
    public func entry(forID id: String) -> Entry? {
        entries.first { $0.id == id }
    }

    /// Resolves a canonical CLI spelling or alias, case-insensitively.
    public func entry(forCLIArgument rawValue: String) -> Entry? {
        let argument = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.first { entry in
            entry.id.lowercased() == argument
                || entry.cliArgument.lowercased() == argument
                || entry.cliAliases.contains(where: { $0.lowercased() == argument })
        }
    }

    /// Canonical names followed by aliases, in display/help order.
    public var cliArguments: [String] {
        entries.flatMap { [$0.cliArgument] + $0.cliAliases }
    }

    /// Compact pipe-separated vocabulary suitable for usage text.
    public var cliArgumentsDescription: String {
        cliArguments.joined(separator: "|")
    }

    /// Returns the canonical CLI spelling for an arbitrary accepted argument.
    public func canonicalCLIArgument(_ rawValue: String) -> String? {
        entry(forCLIArgument: rawValue)?.cliArgument
    }
}
