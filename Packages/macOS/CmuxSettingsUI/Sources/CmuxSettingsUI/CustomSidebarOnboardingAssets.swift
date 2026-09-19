import Foundation

public struct CustomSidebarExampleOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let suggestedName: String

    public init(id: String, title: String, suggestedName: String) {
        self.id = id
        self.title = title
        self.suggestedName = suggestedName
    }
}

public struct CustomSidebarTemplate: Equatable, Sendable {
    public let suggestedName: String
    public let fileExtension: String
    public let source: String

    public init(suggestedName: String, fileExtension: String, source: String) {
        self.suggestedName = suggestedName
        self.fileExtension = fileExtension
        self.source = source
    }
}

public enum CustomSidebarOnboardingResult: Equatable, Sendable {
    case created(name: String)
    case invalidName
    case alreadyExists
    case templateUnavailable
    case writeFailed
}

/// Small files bundled with Settings so onboarding works in installed builds
/// without embedding sidebar source text in the SwiftUI view.
public enum CustomSidebarOnboardingAssets {
    public static var examples: [CustomSidebarExampleOption] {
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

    public static func starterTemplate() -> CustomSidebarTemplate? {
        loadTemplate(resource: "starter", fileExtension: "swift", suggestedName: "my-sidebar")
    }

    public static func exampleTemplate(id: String) -> CustomSidebarTemplate? {
        guard let option = examples.first(where: { $0.id == id }) else { return nil }
        return loadTemplate(resource: option.id, fileExtension: "js", suggestedName: option.suggestedName)
    }

    private static func loadTemplate(
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
