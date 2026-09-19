import CmuxSwiftRenderUI
import Foundation

#if DEBUG
private enum CustomSidebarDirectoryOverrideForTesting {
    @TaskLocal static var value: URL?
}
#endif

extension CmuxExtensionSidebarSelection {
    #if DEBUG
    static var customSidebarsDirectoryOverrideForTesting: URL? {
        CustomSidebarDirectoryOverrideForTesting.value
    }

    static func withCustomSidebarsDirectoryForTesting<T>(_ directory: URL, _ body: () throws -> T) rethrows -> T {
        try CustomSidebarDirectoryOverrideForTesting.$value.withValue(directory) {
            try body()
        }
    }
    #endif

    static func customSidebarFileURL(forName name: String) -> URL? {
        customSidebarFileURL(forName: name, sidebarsDirectory: customSidebarsDirectory)
    }

    static func customSidebarFileURL(forName name: String, sidebarsDirectory: URL) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return customSidebarFileURL(
            forProviderId: customSidebarProviderPrefix + trimmed,
            sidebarsDirectory: sidebarsDirectory
        )
    }
}


enum CustomSidebarFileWriteResult: Equatable {
    case created(name: String, fileURL: URL)
    case invalidName
    case alreadyExists
    case invalidTemplate
    case failed
}

extension CmuxExtensionSidebarSelection {
    static func discoveredCustomSidebarNames(
        sidebarsDirectory: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        CustomSidebarValidator(fileManager: fileManager)
            .discover(in: sidebarsDirectory)
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    @discardableResult
    static func ensureCustomSidebarsDirectory(
        _ directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func writeCustomSidebar(
        named rawName: String,
        fileExtension: String,
        source: String,
        uniquingIfNeeded: Bool,
        sidebarsDirectory: URL,
        fileManager: FileManager = .default
    ) -> CustomSidebarFileWriteResult {
        guard let normalizedName = normalizedCustomSidebarName(rawName) else {
            return .invalidName
        }

        let normalizedExtension = fileExtension.lowercased()
        guard ["js", "swift", "json"].contains(normalizedExtension) else {
            return .invalidTemplate
        }

        do {
            try ensureCustomSidebarsDirectory(sidebarsDirectory, fileManager: fileManager)
            let validator = CustomSidebarValidator(fileManager: fileManager)
            var destinationName = normalizedName

            if uniquingIfNeeded {
                var suffix = 2
                while !validator.discover(in: sidebarsDirectory, name: destinationName).isEmpty {
                    destinationName = "\(normalizedName)-\(suffix)"
                    suffix += 1
                }
            } else if !validator.discover(in: sidebarsDirectory, name: destinationName).isEmpty {
                return .alreadyExists
            }

            let fileURL = sidebarsDirectory.appendingPathComponent(
                "\(destinationName).\(normalizedExtension)",
                isDirectory: false
            )
            try source.write(to: fileURL, atomically: true, encoding: .utf8)

            let validation = validator.validate(fileURL: fileURL)
            guard validation.errorMessage == nil else {
                try? fileManager.removeItem(at: fileURL)
                return .invalidTemplate
            }

            return .created(name: destinationName, fileURL: fileURL)
        } catch {
            return .failed
        }
    }

    static func normalizedCustomSidebarName(_ rawName: String) -> String? {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = name.lowercased()
        for suffix in [".swift", ".js", ".json"] where lowered.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\"),
              name.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        return name
    }
}
