public import CmuxNextActions

/// Makes a new object of one target kind from a name typed into an argument page that lists none
/// by that name: New Tab with Browser Profile… typed "austin" offers Create Browser Profile
/// “austin”, which makes the profile and then runs the action on it.
///
/// The App registers one per kind it can make (``PaletteSources/targetCreators``).
///
/// ```swift
/// sources.targetCreators[.browserProfile] = PaletteTargetCreator(
///     title: { name in AppStrings.createBrowserProfile(name) },
///     symbol: "person.crop.circle.badge.plus"
/// ) { name in try await profiles.createProfile(name: name, color: nil, icon: nil) }
/// ```
public struct PaletteTargetCreator {
    /// The row's title for a typed name, such as "Create Browser Profile “austin”".
    public var title: @MainActor (String) -> String
    /// The row's SF Symbol.
    public var symbol: String
    /// Makes the object named by the trimmed query and returns its target id, which the action
    /// then runs with. A thrown error is shown to the user (a `LocalizedError`'s
    /// `errorDescription`, else its `description`) and the action does not run.
    public var create: @MainActor (String) async throws -> String

    /// - Parameters:
    ///   - title: The row's title for a typed name.
    ///   - symbol: The row's SF Symbol.
    ///   - create: Makes the object and returns its target id.
    public init(title: @escaping @MainActor (String) -> String, symbol: String,
                create: @escaping @MainActor (String) async throws -> String) {
        self.title = title
        self.symbol = symbol
        self.create = create
    }
}
