import Foundation

/// Marker for the entity a durable string id names.
public protocol DaemonStringIDKind: Sendable {}

/// Durable string id (survives daemon restarts), typed by a phantom `Kind`.
public struct DaemonStringID<Kind: DaemonStringIDKind>: RawRepresentable, Hashable, Sendable, Codable,
    CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.init(rawValue: value) }

    /// Accepts a JSON number too, so an unexpected numeric id never fails
    /// the enclosing event.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(UInt64.self) {
            self.init(rawValue: String(number))
        } else {
            self.init(rawValue: try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

public enum StringIDKind {
    public enum WorkspaceKey: DaemonStringIDKind {}
    public enum Terminal: DaemonStringIDKind {}
    public enum TerminalIncarnation: DaemonStringIDKind {}
    public enum Resource: DaemonStringIDKind {}
    public enum Generation: DaemonStringIDKind {}
    public enum WorkspaceGroup: DaemonStringIDKind {}
    public enum ClientTransaction: DaemonStringIDKind {}
    public enum TabGroup: DaemonStringIDKind {}
    public enum SavedTabGroup: DaemonStringIDKind {}
    public enum Profile: DaemonStringIDKind {}
    public enum BrowserProfile: DaemonStringIDKind {}
    public enum ScreenGroup: DaemonStringIDKind {}
    public enum SavedScreenGroup: DaemonStringIDKind {}
}

/// Durable workspace identity: lowercase canonical UUID.
public typealias WorkspaceKey = DaemonStringID<StringIDKind.WorkspaceKey>
/// Durable terminal identity (32 hex characters), survives restarts and moves.
public typealias TerminalID = DaemonStringID<StringIDKind.Terminal>
/// Changes each time a terminal's process is (re)spawned under the same id.
public typealias TerminalIncarnation = DaemonStringID<StringIDKind.TerminalIncarnation>
/// Durable `resource_id` of a workspace, screen, pane, tab, or terminal
/// (`ws_…`, `screen_…`, `pane_…`, `tab_…`, `term_…`).
public typealias ResourceID = DaemonStringID<StringIDKind.Resource>
/// Daemon boot UUID. A change means every numeric handle is invalid.
public typealias DaemonGeneration = DaemonStringID<StringIDKind.Generation>
/// Sidebar group id (`workspace-groups-v1`): 1-64 of `[A-Za-z0-9_.:-]`;
/// the daemon generates `grp_<32 hex>` when the caller omits it.
public typealias WorkspaceGroupID = DaemonStringID<StringIDKind.WorkspaceGroup>
/// Client-chosen tab-drag `transaction`, echoed in the moved tab's `tab-changed`.
public typealias ClientTransactionID = DaemonStringID<StringIDKind.ClientTransaction>

/// Tab group id (`tab-groups-v1`): 1-64 of `[A-Za-z0-9_.:-]`;
/// the daemon generates `tgrp_<32 hex>` when the caller omits it.
public typealias TabGroupID = DaemonStringID<StringIDKind.TabGroup>
/// Session-wide saved tab group record (`saved-tab-groups-v1`).
public typealias SavedTabGroupID = DaemonStringID<StringIDKind.SavedTabGroup>

extension DaemonStringID where Kind == StringIDKind.WorkspaceKey {
    /// A fresh key in the daemon's canonical form; derived from the running
    /// action's idempotency key when there is one (`DaemonCommandScope`).
    public static func generate() -> Self {
        let uuid = DaemonCommandScope.current?.nextDerivedUUID("workspace-key") ?? UUID()
        return Self(rawValue: uuid.uuidString.lowercased())
    }
}

extension DaemonStringID where Kind == StringIDKind.Terminal {
    /// A caller-reserved id for `create-terminal` (canonical 32-character UUID).
    public static func generate() -> Self {
        let uuid = DaemonCommandScope.current?.nextDerivedUUID("terminal-id") ?? UUID()
        return Self(rawValue: uuid.uuidString.lowercased().replacingOccurrences(of: "-", with: ""))
    }
}

extension DaemonStringID where Kind == StringIDKind.ClientTransaction {
    public static func generate() -> Self { Self(rawValue: UUID().uuidString.lowercased()) }
}

/// Profile id (`profiles-v1`, plans/cmux-next/data-model.md): `default` for
/// the built-in profile, else 1-64 of `[A-Za-z0-9_.:-]`; the app generates
/// `prof_<32 hex>`.
public typealias ProfileID = DaemonStringID<StringIDKind.Profile>

extension DaemonStringID where Kind == StringIDKind.Profile {
    /// The built-in profile. Workspaces without a profile belong to it.
    public static let defaultProfile: Self = "default"

    /// A fresh id in the form the daemon mints.
    public static func generate() -> Self {
        Self(rawValue: "prof_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))
    }
}

/// Browser profile id (`profiles-v1`): `default` for the built-in browser
/// profile, else a lowercase UUID that keys the engines' storage.
public typealias BrowserProfileKey = DaemonStringID<StringIDKind.BrowserProfile>

extension DaemonStringID where Kind == StringIDKind.BrowserProfile {
    public static let defaultProfile: Self = "default"
    public static func generate() -> Self { Self(rawValue: UUID().uuidString.lowercased()) }
}

/// Screen group id (`screen-groups-v1`), `sgrp_<32 hex>`.
public typealias ScreenGroupID = DaemonStringID<StringIDKind.ScreenGroup>
/// Saved screen group id (`screen-groups-v1`), `ssaved_<32 hex>`.
public typealias SavedScreenGroupID = DaemonStringID<StringIDKind.SavedScreenGroup>
