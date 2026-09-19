import CmuxSwiftRenderUI
import Foundation
import Darwin

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
            // Validate a private, complete file before publishing it. Never validate
            // or remove a destination that another process might have replaced.
            let stagingDirectory = sidebarsDirectory.appendingPathComponent(".cmux-create-\(UUID().uuidString)")
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
            defer { try? fileManager.removeItem(at: stagingDirectory) }
            let stagedFile = stagingDirectory.appendingPathComponent("sidebar.\(normalizedExtension)")
            try source.write(to: stagedFile, atomically: false, encoding: .utf8)
            guard validator.validate(fileURL: stagedFile).errorMessage == nil else {
                return .invalidTemplate
            }

            var destinationName = normalizedName
            var suffix = 2
            while true {
                let fileURL = sidebarsDirectory.appendingPathComponent("\(destinationName).\(normalizedExtension)")
                let nameExists = validator.discover(in: sidebarsDirectory).contains {
                    $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(destinationName) == .orderedSame
                }
                if !nameExists {
                    // link(2) publishes complete bytes atomically and fails with
                    // EEXIST for any occupied path, including dangling symlinks.
                    // Unlike an atomic replace, it cannot overwrite a race winner.
                    if link(stagedFile.path, fileURL.path) == 0 {
                        return .created(name: destinationName, fileURL: fileURL)
                    }
                    guard errno == EEXIST else { return .failed }
                }
                guard uniquingIfNeeded else { return .alreadyExists }
                destinationName = "\(normalizedName)-\(suffix)"
                suffix += 1
            }
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
