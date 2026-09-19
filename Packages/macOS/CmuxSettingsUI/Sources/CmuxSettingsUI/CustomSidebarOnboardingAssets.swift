import Foundation

/// Loads the small starter and example files bundled with CmuxSettingsUI.
public struct CustomSidebarOnboardingAssets: Sendable {
    struct ExampleOption: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let suggestedName: String
    }

    /// Creates an asset loader for the package's bundled onboarding files.
    public init() {}

    var examples: [ExampleOption] {
        [
            ExampleOption(
                id: "focus",
                title: "focus.js",
                suggestedName: "focus"
            ),
            ExampleOption(
                id: "activity",
                title: "activity.js",
                suggestedName: "activity"
            ),
        ]
    }

    /// Loads the known-good interpreted-Swift starter sidebar.
    ///
    /// - Returns: The bundled starter template, or nil when its resource is unavailable.
    public func starterTemplate() -> CustomSidebarTemplate? {
        loadTemplate(resource: "starter", fileExtension: "swift", suggestedName: "my-sidebar")
    }

    /// Loads one bundled custom-sidebar example.
    ///
    /// - Parameter id: Stable example identifier from the Settings onboarding menu.
    /// - Returns: The matching bundled template, or nil when the identifier or resource is unavailable.
    public func exampleTemplate(id: String) -> CustomSidebarTemplate? {
        guard let option = examples.first(where: { $0.id == id }) else { return nil }
        return loadTemplate(resource: option.id, fileExtension: "js", suggestedName: option.suggestedName)
    }

    private func loadTemplate(
        resource: String,
        fileExtension: String,
        suggestedName: String
    ) -> CustomSidebarTemplate? {
        guard let url = Bundle.module.url(
            forResource: resource,
            withExtension: fileExtension,
            subdirectory: "CustomSidebars"
        ),
        let source = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return CustomSidebarTemplate(
            suggestedName: suggestedName,
            fileExtension: fileExtension,
            source: source
        )
    }
}
