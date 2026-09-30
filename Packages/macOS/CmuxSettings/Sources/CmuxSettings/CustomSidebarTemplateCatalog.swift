import Foundation

/// The side of the cmux chrome a bundled template is designed for.
public enum CustomSidebarTemplateKind: String, Codable, CaseIterable, Sendable {
    case left
    case right
    case both
}

/// Metadata for one bundled custom-sidebar template.
public struct CustomSidebarTemplateDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let file: String
    public let displayNameKey: String
    public let displayName: String
    public let descriptionKey: String
    public let description: String
    public let kind: CustomSidebarTemplateKind

    public init(
        id: String,
        file: String,
        displayNameKey: String,
        displayName: String,
        descriptionKey: String,
        description: String,
        kind: CustomSidebarTemplateKind
    ) {
        self.id = id
        self.file = file
        self.displayNameKey = displayNameKey
        self.displayName = displayName
        self.descriptionKey = descriptionKey
        self.description = description
        self.kind = kind
    }
}

/// A descriptor plus the source copied when a user installs the template.
public struct CustomSidebarTemplate: Equatable, Sendable {
    public let descriptor: CustomSidebarTemplateDescriptor
    public let source: String

    public var id: String { descriptor.id }
    public var suggestedName: String { descriptor.id }
    public var fileExtension: String { URL(fileURLWithPath: descriptor.file).pathExtension.lowercased() }

    public init(descriptor: CustomSidebarTemplateDescriptor, source: String) {
        self.descriptor = descriptor
        self.source = source
    }
}

/// Loads the manifest and source files shared by the app and CLI.
public struct CustomSidebarTemplateCatalog: Sendable {
    private let resourceDirectory: URL
    private let descriptorsByID: [String: CustomSidebarTemplateDescriptor]

    public init(bundle: Bundle = .module) {
        resourceDirectory = bundle.url(
            forResource: "CustomSidebarTemplates",
            withExtension: nil
        ) ?? bundle.resourceURL?.appendingPathComponent("CustomSidebarTemplates", isDirectory: true)
            ?? URL(fileURLWithPath: "/__cmux_missing_custom_sidebar_templates", isDirectory: true)
        let manifestURL = resourceDirectory.appendingPathComponent("manifest.json", isDirectory: false)
        let descriptors: [CustomSidebarTemplateDescriptor]
        if let data = try? Data(contentsOf: manifestURL),
           let decoded = try? JSONDecoder().decode(Manifest.self, from: data) {
            descriptors = decoded.templates
        } else {
            descriptors = []
        }
        descriptorsByID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
    }

    public var templates: [CustomSidebarTemplateDescriptor] {
        descriptorsByID.values.sorted { $0.id < $1.id }
    }

    public func template(id: String) -> CustomSidebarTemplate? {
        guard let descriptor = descriptorsByID[id],
              let source = try? String(
                  contentsOf: resourceDirectory.appendingPathComponent(descriptor.file, isDirectory: false),
                  encoding: .utf8
              ) else {
            return nil
        }
        let installedSource = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//   cp Examples/CustomSidebars/") }
            .joined(separator: "\n")
        return CustomSidebarTemplate(descriptor: descriptor, source: installedSource)
    }

    public static func isValidInstallationName(_ name: String) -> Bool {
        let pattern = #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    private struct Manifest: Decodable {
        let templates: [CustomSidebarTemplateDescriptor]
    }
}
