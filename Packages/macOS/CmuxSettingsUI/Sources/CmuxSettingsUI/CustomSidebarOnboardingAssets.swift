import Foundation

struct CustomSidebarExampleOption: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let suggestedName: String
}

/// A validated source template that the host can copy into the user's sidebar directory.
public struct CustomSidebarTemplate: Equatable, Sendable {
    /// Suggested file stem for the generated sidebar.
    public let suggestedName: String

    /// File extension understood by the existing custom-sidebar validator.
    public let fileExtension: String

    /// Sidebar source copied into the user's custom-sidebar directory.
    public let source: String

    /// Creates a custom-sidebar template.
    ///
    /// - Parameters:
    ///   - suggestedName: Suggested file stem for the generated sidebar.
    ///   - fileExtension: File extension accepted by the custom-sidebar runtime.
    ///   - source: Sidebar source text.
    public init(suggestedName: String, fileExtension: String, source: String) {
        self.suggestedName = suggestedName
        self.fileExtension = fileExtension
        self.source = source
    }
}

/// Outcome returned by host-owned custom-sidebar onboarding actions.
public enum CustomSidebarOnboardingResult: Equatable, Sendable {
    /// A sidebar file was created successfully.
    case created(name: String)

    /// The requested file name cannot be used safely.
    case invalidName

    /// A discovered sidebar already uses the requested name.
    case alreadyExists

    /// A bundled starter or example could not be loaded or validated.
    case templateUnavailable

    /// The host could not write the sidebar file.
    case writeFailed
}

/// Loads the small starter and example files bundled with CmuxSettingsUI.
public struct CustomSidebarOnboardingAssets: Sendable {
    /// Creates an asset loader for the package's bundled onboarding files.
    public init() {}

    var examples: [CustomSidebarExampleOption] {
        [
            CustomSidebarExampleOption(
                id: "focus",
                title: "focus.js",
                suggestedName: "focus"
            ),
            CustomSidebarExampleOption(
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
