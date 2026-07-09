import Foundation
import Testing
@testable import CmuxTerminalCore

/// Verifies the resources-directory preference order: this app's complete
/// bundle, then the inherited environment value, then a system Ghostty.app
/// install, then an incomplete bundled copy.
@Suite struct GhosttyResourcesDirectoryResolverTests {
    @Test func preferCurrentBundleOverInheritedEnvironment() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-launch-resources-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let inheritedResources = root.appendingPathComponent("inherited/ghostty", isDirectory: true)
        let bundleResources = root.appendingPathComponent("BundleResources", isDirectory: true)
        let bundledGhostty = bundleResources.appendingPathComponent("ghostty", isDirectory: true)
        try fileManager.createDirectory(
            at: inheritedResources.appendingPathComponent("themes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: bundledGhostty.appendingPathComponent("themes", isDirectory: true),
            withIntermediateDirectories: true
        )

        let resolver = GhosttyResourcesDirectoryResolver(
            ghosttyAppResources: root.appendingPathComponent("missing", isDirectory: true).path,
            fileExists: { FileManager.default.fileExists(atPath: $0) }
            )
        let resolved = resolver.resolve(
            currentValue: inheritedResources.path,
            bundleResourceURL: bundleResources
        )

        #expect(resolved == bundledGhostty.path)
    }

    @Test func keepInheritedEnvironmentWhenBundleHasNoResources() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-launch-resource-fallback-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let inheritedResources = root.appendingPathComponent("inherited/ghostty", isDirectory: true)
        let emptyBundleResources = root.appendingPathComponent("BundleResources", isDirectory: true)
        try fileManager.createDirectory(at: inheritedResources, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: emptyBundleResources, withIntermediateDirectories: true)

        let resolver = GhosttyResourcesDirectoryResolver(
            ghosttyAppResources: root.appendingPathComponent("missing", isDirectory: true).path,
            fileExists: { FileManager.default.fileExists(atPath: $0) }
            )
        let resolved = resolver.resolve(
            currentValue: inheritedResources.path,
            bundleResourceURL: emptyBundleResources
        )

        #expect(resolved == inheritedResources.path)
    }

    @Test func keepInheritedEnvironmentWhenBundleLacksThemes() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-launch-incomplete-resource-fallback-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let inheritedResources = root.appendingPathComponent("inherited/ghostty", isDirectory: true)
        let bundleResources = root.appendingPathComponent("BundleResources", isDirectory: true)
        let bundledGhostty = bundleResources.appendingPathComponent("ghostty", isDirectory: true)
        try fileManager.createDirectory(
            at: inheritedResources.appendingPathComponent("themes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: bundledGhostty, withIntermediateDirectories: true)

        let resolver = GhosttyResourcesDirectoryResolver(
            ghosttyAppResources: root.appendingPathComponent("missing", isDirectory: true).path,
            fileExists: { FileManager.default.fileExists(atPath: $0) }
            )
        let resolved = resolver.resolve(
            currentValue: inheritedResources.path,
            bundleResourceURL: bundleResources
        )

        #expect(resolved == inheritedResources.path)
    }

    @Test func useIncompleteBundleOnlyAsLastFallback() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-launch-incomplete-resource-last-fallback-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let bundleResources = root.appendingPathComponent("BundleResources", isDirectory: true)
        let bundledGhostty = bundleResources.appendingPathComponent("ghostty", isDirectory: true)
        try fileManager.createDirectory(at: bundledGhostty, withIntermediateDirectories: true)

        let resolver = GhosttyResourcesDirectoryResolver(
            ghosttyAppResources: root.appendingPathComponent("missing-app", isDirectory: true).path,
            fileExists: { FileManager.default.fileExists(atPath: $0) }
            )
        let resolved = resolver.resolve(
            currentValue: root.appendingPathComponent("missing-inherited", isDirectory: true).path,
            bundleResourceURL: bundleResources
        )

        #expect(resolved == bundledGhostty.path)
    }
}
