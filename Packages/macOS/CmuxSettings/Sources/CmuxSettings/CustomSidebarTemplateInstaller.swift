import Foundation

public enum CustomSidebarTemplateInstallError: Error, Equatable, Sendable {
    case invalidName
    case unknownTemplate
    case alreadyExists
    case writeFailed
}

/// Installs a bundled template into a user's custom-sidebar directory.
public struct CustomSidebarTemplateInstaller: Sendable {
    private let catalog: CustomSidebarTemplateCatalog

    public init(catalog: CustomSidebarTemplateCatalog = CustomSidebarTemplateCatalog()) {
        self.catalog = catalog
    }

    @discardableResult
    public func install(
        name: String,
        templateID: String,
        directory: URL,
        force: Bool = false,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard CustomSidebarTemplateCatalog.isValidInstallationName(name) else {
            throw CustomSidebarTemplateInstallError.invalidName
        }
        guard let template = catalog.template(id: templateID) else {
            throw CustomSidebarTemplateInstallError.unknownTemplate
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let matchingURLs = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.deletingPathExtension().lastPathComponent == name && ["js", "swift", "json"].contains($0.pathExtension.lowercased()) }
            if !matchingURLs.isEmpty, !force {
                throw CustomSidebarTemplateInstallError.alreadyExists
            }
            if force {
                for url in matchingURLs { try fileManager.removeItem(at: url) }
            }
            let destination = directory.appendingPathComponent("\(name).\(template.fileExtension)", isDirectory: false)
            try Data(template.source.utf8).write(to: destination, options: .atomic)
            return destination
        } catch let error as CustomSidebarTemplateInstallError {
            throw error
        } catch {
            throw CustomSidebarTemplateInstallError.writeFailed
        }
    }
}
