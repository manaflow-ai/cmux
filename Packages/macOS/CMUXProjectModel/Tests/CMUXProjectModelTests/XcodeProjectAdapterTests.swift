import Foundation
import Testing
@testable import CMUXProjectModel

@Suite("XcodeProjectAdapter against cmux.xcodeproj")
struct XcodeProjectAdapterTests {
    private let workspaceURL: URL
    private let projectURL: URL

    /// How many directories the search below looks at, counting the one holding
    /// this file. This file sits five levels below the worktree root today, so
    /// six candidates cover the current layout and eight leaves a little room.
    private static let searchedDirectoryCount = 8

    init() throws {
        let env = ProcessInfo.processInfo.environment
        if let override = env["CMUX_PROJECT_FIXTURE"] {
            let base = URL(fileURLWithPath: override)
            self.workspaceURL = base.pathExtension.lowercased() == "xcworkspace" ? base : base.appendingPathComponent("cmux.xcworkspace")
            self.projectURL = base.pathExtension.lowercased() == "xcodeproj" ? base : base.appendingPathComponent("cmux.xcodeproj")
        } else {
            let start = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
            guard let worktreeRoot = Self.worktreeRootContainingProject(startingAt: start) else {
                throw ProjectNotFoundError(searchStart: start, searchedDirectoryCount: Self.searchedDirectoryCount)
            }
            self.workspaceURL = worktreeRoot.appendingPathComponent("cmux.xcworkspace")
            self.projectURL = worktreeRoot.appendingPathComponent("cmux.xcodeproj")
        }
    }

    /// Returns the nearest directory at or above `start` that holds cmux.xcodeproj,
    /// or nil when none of the `searchedDirectoryCount` directories it looks at has one.
    ///
    /// Packages move between the Packages/Shared, Packages/iOS and Packages/macOS
    /// group folders, which changes how deep this file sits, and counting parent
    /// directories silently points at the wrong root when that happens. The search
    /// stops after a fixed number of levels so that a checkout nested inside another
    /// checkout cannot bind these tests to the outer checkout's project.
    private static func worktreeRootContainingProject(startingAt start: URL) -> URL? {
        var directory = start
        for _ in 0..<searchedDirectoryCount {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("cmux.xcodeproj").path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    private struct ProjectNotFoundError: Error, CustomStringConvertible {
        let searchStart: URL
        let searchedDirectoryCount: Int

        var description: String {
            """
            cmux.xcodeproj is not in \(searchStart.path) or in any of the \
            \(searchedDirectoryCount - 1) directories above it, so these tests have no \
            project to load. Run them from a cmux checkout, or point \
            CMUX_PROJECT_FIXTURE at a directory that contains cmux.xcodeproj.
            """
        }
    }

    @Test
    func loadsCmuxXcodeprojIntoOneModule() throws {
        let adapter = XcodeProjectAdapter()
        let model = try adapter.load(at: projectURL)
        #expect(model.adapter == .xcode)
        #expect(model.modules.count == 1)
        let module = try #require(model.modules.first)
        #expect(!module.targets.isEmpty)
        #expect(module.rootGroup.children.isEmpty == false)
    }

    @Test
    func findsCmuxAppTargetWithApplicationProductType() throws {
        let adapter = XcodeProjectAdapter()
        let model = try adapter.load(at: projectURL)
        let module = try #require(model.modules.first)
        let cmuxTarget = module.targets.first(where: { $0.displayName == "cmux" })
        let summary = try #require(cmuxTarget)
        #expect(summary.productType == .application)
    }

    @Test
    func navigatorTreeHasSourcesGroup() throws {
        let adapter = XcodeProjectAdapter()
        let model = try adapter.load(at: projectURL)
        let module = try #require(model.modules.first)
        let names = topLevelGroupNames(in: module.rootGroup)
        #expect(names.contains(where: { $0.lowercased().contains("source") || $0 == "Sources" }))
    }

    @Test
    func workspaceLoadIncludesAtLeastOneModule() throws {
        guard FileManager.default.fileExists(atPath: workspaceURL.path) else { return }
        let adapter = XcodeProjectAdapter()
        let model = try adapter.load(at: workspaceURL)
        #expect(model.adapter == .xcode)
        #expect(!model.modules.isEmpty)
    }

    @Test
    func canLoadAcceptsXcodeprojDirectly() {
        let adapter = XcodeProjectAdapter()
        #expect(adapter.canLoad(projectURL))
    }

    @Test
    func canLoadAcceptsDirectoryContainingProject() {
        let adapter = XcodeProjectAdapter()
        #expect(adapter.canLoad(projectURL.deletingLastPathComponent()))
    }

    @Test
    func bundleIdentifierIsEitherResolvedOrExplicitlyNilNotFabricated() throws {
        let adapter = XcodeProjectAdapter()
        let model = try adapter.load(at: projectURL)
        let module = try #require(model.modules.first)
        let cmux = try #require(module.targets.first(where: { $0.displayName == "cmux" }))
        if let bundle = cmux.bundleIdentifier {
            #expect(!bundle.isEmpty)
            #expect(!bundle.contains("$("), "Bundle ID should be resolved, not contain unresolved $(...) variables: \(bundle)")
        }
    }

    @Test
    func unresolvableSchemeTargetsReturnNilNotFabricatedID() throws {
        let adapter = XcodeProjectAdapter()
        let model = try adapter.load(at: projectURL)
        let module = try #require(model.modules.first)
        let knownTargetIDs = Set(module.targets.map(\.id))
        for scheme in module.schemes {
            for targetID in scheme.runTargetIDs + scheme.testTargetIDs {
                #expect(knownTargetIDs.contains(targetID),
                       "Scheme \(scheme.name) references target ID \(targetID.rawValue) that is not in the module's target list")
            }
        }
    }

    @Test
    func loadReportsAtLeastOneBuildConfigurationPerKnownTarget() throws {
        let adapter = XcodeProjectAdapter()
        let model = try adapter.load(at: projectURL)
        let module = try #require(model.modules.first)
        #expect(module.configurationNames.contains("Debug") || module.configurationNames.contains("Release"))
        for target in module.targets {
            let targetConfigs = module.configurations.filter { config in
                if case let .target(id) = config.scope, id == target.id { return true }
                return false
            }
            #expect(!targetConfigs.isEmpty, "Target \(target.displayName) has no build configurations")
        }
    }

    private func topLevelGroupNames(in group: ProjectGroup) -> [String] {
        group.children.compactMap { node in
            if case let .group(child) = node { return child.displayName }
            return nil
        }
    }
}
