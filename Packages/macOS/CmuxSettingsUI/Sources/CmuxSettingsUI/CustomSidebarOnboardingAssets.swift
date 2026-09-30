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
            source: source
        )
    }

    public func exampleTemplate(id: String) -> CustomSidebarTemplate? {
        catalog.template(id: id)
    }
}
