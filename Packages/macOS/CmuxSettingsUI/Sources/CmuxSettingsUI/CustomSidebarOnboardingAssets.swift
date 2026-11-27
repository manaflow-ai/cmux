import CmuxSettings
import Foundation

/// Loads bundled custom-sidebar templates for Settings onboarding.
public struct CustomSidebarOnboardingAssets: Sendable {
    public typealias ExampleOption = CustomSidebarTemplateDescriptor
    private let catalog: CustomSidebarTemplateCatalog

    public init() {
        catalog = CustomSidebarTemplateCatalog()
    }

    public var templates: [CustomSidebarTemplateDescriptor] {
        catalog.templates
    }

    public func previewImageURL(id: String) -> URL? {
        previewImageURL(id: id, theme: "dark")
    }

    /// Returns the bundled light or dark preview image for a template.
    /// - Parameters:
    ///   - id: The template identifier.
    ///   - theme: `light` or `dark`.
    public func previewImageURL(id: String, theme: String) -> URL? {
        Bundle.module.url(
            forResource: "\(id)-\(theme)",
            withExtension: "png",
            subdirectory: "CustomSidebarTemplatePreviews"
        )
    }

    /// Loads the known-good interpreted-Swift starter sidebar.
    public func starterTemplate() -> CustomSidebarTemplate? {
        guard let sourceURL = Bundle.module.url(
            forResource: "starter",
            withExtension: "swift",
            subdirectory: "CustomSidebars"
        ), let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            return nil
        }
        return CustomSidebarTemplate(
            descriptor: CustomSidebarTemplateDescriptor(
                id: "starter",
                file: "starter.swift",
                displayNameKey: "sidebar.template.starter.name",
                displayName: "Starter",
                descriptionKey: "sidebar.template.starter.description",
                description: "A minimal workspace list to use as a starting point.",
                kind: .left
            ),
            source: source,
            suggestedName: "my-sidebar"
        )
    }

    public func exampleTemplate(id: String) -> CustomSidebarTemplate? {
        catalog.template(id: id)
    }
}
