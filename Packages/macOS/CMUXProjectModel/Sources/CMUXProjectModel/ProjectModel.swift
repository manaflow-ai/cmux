import Foundation

/// A parsed snapshot of a project that can be rendered by the project pane.
///
/// ``ProjectModel`` is an immutable value type. Reactive updates are
/// expressed by replacing the snapshot wholesale, which lets the UI diff two
/// snapshots cheaply (`Hashable` on every nested type) without reasoning
/// about partial mutation. Build a new model with ``ProjectAdapter`` on each
/// underlying file change.
///
/// Example:
/// ```swift
/// let model = try XcodeProjectAdapter().load(
///     at: URL(fileURLWithPath: "/path/to/cmux.xcworkspace")
/// )
/// for module in model.modules {
///     print(module.displayName, module.targets.count)
/// }
/// ```
public struct ProjectModel: Sendable, Hashable, Identifiable {
    public let id: ProjectModelID
    public let displayName: String
    public let rootURL: URL
    public let adapter: ProjectAdapterKind
    public let modules: [ProjectModule]

    public init(
        id: ProjectModelID,
        displayName: String,
        rootURL: URL,
        adapter: ProjectAdapterKind,
        modules: [ProjectModule]
    ) {
        self.id = id
        self.displayName = displayName
        self.rootURL = rootURL
        self.adapter = adapter
        self.modules = modules
    }

    /// Look up a module by id.
    public func module(for id: ProjectModuleID) -> ProjectModule? {
        modules.first(where: { $0.id == id })
    }
}
