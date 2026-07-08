import Foundation
import Testing
@testable import CMUXProjectModel

@Suite("XcodeProjectAdapter against cmux.xcodeproj")
struct XcodeProjectAdapterTests {
    private let workspaceURL: URL
    private let projectURL: URL

    init() {
        let env = ProcessInfo.processInfo.environment
        if let override = env["CMUX_PROJECT_FIXTURE"] {
            let base = URL(fileURLWithPath: override)
            self.workspaceURL = base.pathExtension.lowercased() == "xcworkspace" ? base : base.appendingPathComponent("cmux.xcworkspace")
            self.projectURL = base.pathExtension.lowercased() == "xcodeproj" ? base : base.appendingPathComponent("cmux.xcodeproj")
        } else {
            let here = URL(fileURLWithPath: #filePath)
            let worktreeRoot = here
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            self.workspaceURL = worktreeRoot.appendingPathComponent("cmux.xcworkspace")
            self.projectURL = worktreeRoot.appendingPathComponent("cmux.xcodeproj")
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
