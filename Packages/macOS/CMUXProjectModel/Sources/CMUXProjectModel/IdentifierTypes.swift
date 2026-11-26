import Foundation

/// Stable identifier for a parsed ``ProjectModel``.
///
/// The raw value is a content-derived hash (typically the absolute path of the
/// root `.xcworkspace` or `.xcodeproj`) so the identifier survives reloads even
/// when the underlying file is rewritten by the IDE.
public struct ProjectModelID: Sendable, Hashable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Identifier for a ``ProjectModule`` within a ``ProjectModel``.
///
/// For the Xcode adapter this is the `.xcodeproj` bundle path scoped under the
/// owning workspace. For other adapters (Cargo, Gradle, etc.) it is the
/// canonical module path declared by that ecosystem.
public struct ProjectModuleID: Sendable, Hashable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Identifier for a node (group or file) inside a ``ProjectModule``'s
/// navigator tree.
///
/// Content-derived: for the Xcode adapter this combines the module ID, the
/// parent path inside the navigator, and the node's display name. UI state
/// (expansion, selection, scroll position) keyed on ``ProjectNodeID`` must
/// therefore survive a `pbxproj` rewrite that does not change the visible
/// tree, even when Xcode regenerates the underlying object UUIDs.
public struct ProjectNodeID: Sendable, Hashable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Identifier for a build target inside a ``ProjectModule``.
public struct TargetID: Sendable, Hashable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Identifier for a build configuration (e.g. "Debug" or "Release") attached
/// to either a project or a target.
public struct BuildConfigID: Sendable, Hashable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Identifier for a scheme inside a ``ProjectModel``.
public struct SchemeID: Sendable, Hashable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
