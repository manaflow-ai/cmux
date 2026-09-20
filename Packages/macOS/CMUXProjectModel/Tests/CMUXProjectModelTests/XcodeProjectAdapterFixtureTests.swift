import Foundation
import Testing
@testable import CMUXProjectModel

@Suite("XcodeProjectAdapter against a synthetic project")
struct XcodeProjectAdapterFixtureTests {
    /// Writes `Fixture.xcodeproj` into a fresh directory and removes it afterwards.
    private final class Fixture {
        let root: URL
        let projectURL: URL

        init() throws {
            // The real path, so resolved paths compare equal to what the adapter returns.
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .resolvingSymlinksInPath()
                .appendingPathComponent("cmux-project-fixture-\(UUID().uuidString)")
            projectURL = root.appendingPathComponent("App/Fixture.xcodeproj")
            let schemes = projectURL.appendingPathComponent("xcshareddata/xcschemes")
            try FileManager.default.createDirectory(at: schemes, withIntermediateDirectories: true)
            try Data(Self.pbxproj.utf8).write(to: projectURL.appendingPathComponent("project.pbxproj"))
            try Data(Self.scheme.utf8).write(to: schemes.appendingPathComponent("App.xcscheme"))
            try Data(Self.xcconfig.utf8).write(to: root.appendingPathComponent("App/Base.xcconfig"))
            let storyboard = root.appendingPathComponent("App/Base.lproj/Main.storyboard")
            try FileManager.default.createDirectory(
                at: storyboard.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: storyboard)
        }

        /// Writes `Nested.xcworkspace` next to `App/`, referencing the project from inside located groups.
        func writeWorkspace(_ xml: String) throws -> URL {
            let workspace = root.appendingPathComponent("Nested.xcworkspace")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try Data(xml.utf8).write(to: workspace.appendingPathComponent("contents.xcworkspacedata"))
            return workspace
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func load() throws -> ProjectModule {
            let model = try XcodeProjectAdapter().load(at: projectURL)
            return try #require(model.modules.first)
        }

        static let xcconfig = "IPHONEOS_DEPLOYMENT_TARGET = 17.0\n"

        static let pbxproj = """
        // !$*UTF8*$!
        {
            archiveVersion = 1;
            objectVersion = 77;
            objects = {
                P0 /* Project object */ = {isa = PBXProject; buildConfigurationList = CL0; mainGroup = G0; targets = (T1, T2, T3); };
                G0 = {isa = PBXGroup; children = (G1, F3, F4, F5, F6, V1, S1); sourceTree = "<group>"; };
                G1 /* Sources */ = {isa = PBXGroup; children = (F1, F2); path = Sources; sourceTree = "<group>"; };
                F1 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Main.swift; sourceTree = "<group>"; };
                F2 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = Shared.swift; path = ../../Shared/./Shared.swift; sourceTree = "<group>"; };
                F3 = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Base.xcconfig; sourceTree = SOURCE_ROOT; };
                F4 = {isa = PBXFileReference; lastKnownFileType = text; path = /etc/hosts; sourceTree = "<absolute>"; };
                F5 = {isa = PBXFileReference; explicitFileType = wrapper.application; path = App.app; sourceTree = BUILT_PRODUCTS_DIR; };
                F6 = {isa = PBXFileReference; lastKnownFileType = text; path = Dangling.txt; sourceTree = "<group>"; };
                V1 = {isa = PBXVariantGroup; children = (F7); name = Main.storyboard; sourceTree = "<group>"; };
                F7 = {isa = PBXFileReference; lastKnownFileType = file.storyboard; name = Base; path = Base.lproj/Main.storyboard; sourceTree = "<group>"; };
                S1 = {isa = PBXFileSystemSynchronizedRootGroup; path = Synced; sourceTree = "<group>"; };
                T1 = {isa = PBXNativeTarget; buildConfigurationList = CL1; buildPhases = (BP1, BP2); dependencies = (D1, D2); name = App; productType = "com.apple.product-type.application"; };
                T2 = {isa = PBXAggregateTarget; buildConfigurationList = CL1; buildPhases = (BP3); dependencies = (); name = Everything; };
                T3 = {isa = PBXNativeTarget; buildConfigurationList = CL2; buildPhases = (); dependencies = (); name = Kit; productType = "com.apple.product-type.framework"; };
                BP1 = {isa = PBXSourcesBuildPhase; files = (BF1, BF2, BF4); };
                BP2 = {isa = PBXResourcesBuildPhase; files = (BF3); };
                BP3 = {isa = PBXShellScriptBuildPhase; files = (); };
                BF1 = {isa = PBXBuildFile; fileRef = F1; settings = {COMPILER_FLAGS = "-O -DFOO"; }; };
                BF2 = {isa = PBXBuildFile; fileRef = F2; };
                BF3 = {isa = PBXBuildFile; fileRef = V1; };
                BF4 = {isa = PBXBuildFile; productRef = MISSING; };
                D1 = {isa = PBXTargetDependency; target = T3; };
                D2 = {isa = PBXTargetDependency; targetProxy = PX1; };
                PX1 = {isa = PBXContainerItemProxy; containerPortal = P0; proxyType = 1; remoteGlobalIDString = ELSEWHERE; remoteInfo = Elsewhere; };
                CL0 = {isa = XCConfigurationList; buildConfigurations = (C0); };
                CL1 = {isa = XCConfigurationList; buildConfigurations = (C1); };
                CL2 = {isa = XCConfigurationList; buildConfigurations = (C2); };
                C0 = {isa = XCBuildConfiguration; baseConfigurationReference = F3; buildSettings = {SDKROOT = iphoneos; }; name = Debug; };
                C1 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = dev.cmux.fixture; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; OTHER_LDFLAGS = ("-lc++", "-ObjC"); }; name = Debug; };
                C2 = {isa = XCBuildConfiguration; buildSettings = {}; name = Debug; };
            };
            rootObject = P0;
        }
        """

        static let scheme = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme version="1.7">
          <BuildAction>
            <BuildActionEntries>
              <BuildActionEntry buildForArchiving="YES">
                <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="T3" BuildableName="Kit.framework" BlueprintName="Renamed" ReferencedContainer="container:Fixture.xcodeproj"/>
              </BuildActionEntry>
            </BuildActionEntries>
          </BuildAction>
          <TestAction>
            <Testables>
              <TestableReference skipped="NO">
                <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="GONE" BuildableName="Gone.xctest" BlueprintName="Gone" ReferencedContainer="container:Fixture.xcodeproj"/>
              </TestableReference>
            </Testables>
          </TestAction>
          <LaunchAction>
            <BuildableProductRunnable>
              <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="T1" BuildableName="App.app" BlueprintName="App" ReferencedContainer="container:Fixture.xcodeproj"/>
            </BuildableProductRunnable>
            <CommandLineArguments>
              <CommandLineArgument argument="--verbose" isEnabled="YES"/>
              <CommandLineArgument argument="--off" isEnabled="NO"/>
            </CommandLineArguments>
            <EnvironmentVariables>
              <EnvironmentVariable key="MODE" value="fixture" isEnabled="YES"/>
              <EnvironmentVariable key="SKIPPED" value="1" isEnabled="NO"/>
            </EnvironmentVariables>
          </LaunchAction>
        </Scheme>
        """
    }

    private func file(named name: String, in group: ProjectGroup) -> ProjectFileNode? {
        for child in group.children {
            switch child {
            case let .file(node) where node.displayName == name: return node
            case let .group(sub):
                if let found = file(named: name, in: sub) { return found }
            default: continue
            }
        }
        return nil
    }

    @Test
    func targetMetadataResolvesFromBuildSettingsThenXcconfig() throws {
        let fixture = try Fixture()
        let app = try #require(try fixture.load().targets.first { $0.displayName == "App" })
        #expect(app.bundleIdentifier == "dev.cmux.fixture")
        #expect(app.platforms == ["iphoneos", "iphonesimulator"])
        #expect(app.deploymentTarget == "17.0")
    }

    @Test
    func onlyNativeTargetsAreSummarizedAndDependenciesKeepTheirKind() throws {
        let fixture = try Fixture()
        let module = try fixture.load()
        #expect(module.targets.map(\.displayName) == ["App", "Kit"])
        #expect(module.targets.first?.productType == .application)
        #expect(module.targets.first?.dependencies.map(\.rawValue) == ["T3", "remote:Elsewhere"])
    }

    @Test
    func pathsFollowEachSourceTree() throws {
        let fixture = try Fixture()
        let root = try fixture.load().rootGroup
        let app = fixture.root.appendingPathComponent("App").path
        #expect(file(named: "Main.swift", in: root)?.resolvedPath?.path == "\(app)/Sources/Main.swift")
        #expect(file(named: "Shared.swift", in: root)?.resolvedPath?.path == "\(fixture.root.path)/Shared/Shared.swift")
        #expect(file(named: "Base.xcconfig", in: root)?.resolvedPath?.path == "\(app)/Base.xcconfig")
        #expect(file(named: "Base.xcconfig", in: root)?.existsOnDisk == true)
        #expect(file(named: "/etc/hosts", in: root)?.resolvedPath?.path == "/etc/hosts")
        #expect(file(named: "App.app", in: root)?.resolvedPath == nil)
        #expect(file(named: "App.app", in: root)?.fileType == "wrapper.application")
        #expect(file(named: "Dangling.txt", in: root)?.existsOnDisk == false)
    }

    @Test
    func variantAndSynchronizedGroupsKeepTheirStyle() throws {
        let fixture = try Fixture()
        let groups = try fixture.load().rootGroup.children.compactMap { node -> ProjectGroup? in
            if case let .group(group) = node { return group }
            return nil
        }
        let variant = try #require(groups.first { $0.displayName == "Main.storyboard" })
        #expect(variant.style == .variant)
        #expect(variant.resolvedPath?.path == fixture.root.appendingPathComponent("App/Base.lproj/Main.storyboard").path)
        #expect(groups.first { $0.displayName == "Synced" }?.style == .synchronized)
    }

    @Test
    func variantChildrenResolveBesideTheVariantGroupNotInsideIt() throws {
        let fixture = try Fixture()
        let base = try #require(file(named: "Base", in: try fixture.load().rootGroup))
        #expect(base.resolvedPath?.path == fixture.root.appendingPathComponent("App/Base.lproj/Main.storyboard").path)
        #expect(base.existsOnDisk)
    }

    @Test
    func workspaceReferencesResolveAgainstTheirEnclosingGroups() throws {
        let fixture = try Fixture()
        let workspace = try fixture.writeWorkspace("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version="1.0">
          <Group location="container:App" name="App">
            <FileRef location="group:Fixture.xcodeproj"/>
            <Group location="group:Missing" name="Missing">
              <FileRef location="container:App/Fixture.xcodeproj"/>
            </Group>
          </Group>
        </Workspace>
        """)
        let model = try XcodeProjectAdapter().load(at: workspace)
        #expect(model.modules.map(\.rootURL.path) == [fixture.projectURL.path, fixture.projectURL.path])
    }

    @Test
    func membershipsCarryRoleAndCompilerFlags() throws {
        let fixture = try Fixture()
        let root = try fixture.load().rootGroup
        let main = try #require(file(named: "Main.swift", in: root))
        #expect(main.memberships == [
            TargetMembership(targetID: TargetID(rawValue: "T1"), role: .compile, compilerFlags: ["-O", "-DFOO"])
        ])
        #expect(file(named: "Base.xcconfig", in: root)?.memberships.isEmpty == true)
    }

    @Test
    func configurationsReportScopeBaseFileAndJoinedListSettings() throws {
        let fixture = try Fixture()
        let configurations = try fixture.load().configurations
        let project = try #require(configurations.first { $0.scope == .project })
        #expect(project.baseConfigurationPath?.lastPathComponent == "Base.xcconfig")
        #expect(project.rawSettings == ["SDKROOT": "iphoneos"])
        let app = try #require(configurations.first { $0.scope == .target(TargetID(rawValue: "T1")) })
        #expect(app.rawSettings["OTHER_LDFLAGS"] == "-lc++ -ObjC")
        #expect(configurations.count == 3)
    }

    @Test
    func schemeResolvesTargetsByNameThenIdentifierAndDropsUnknownOnes() throws {
        let fixture = try Fixture()
        let scheme = try #require(try fixture.load().schemes.first)
        #expect(scheme.name == "App")
        #expect(scheme.isShared)
        #expect(scheme.runTargetIDs == [TargetID(rawValue: "T1")])
        #expect(scheme.testTargetIDs.isEmpty)
        #expect(scheme.archiveTargetID == TargetID(rawValue: "T3"))
        #expect(scheme.profileTargetID == nil)
        #expect(scheme.launchArguments == ["--verbose"])
        #expect(scheme.environmentVariables == ["MODE": "fixture"])
    }

    @Test
    func malformedProjectFileReportsAParseFailure() throws {
        let fixture = try Fixture()
        try Data("{ objects = {}; }".utf8).write(to: fixture.projectURL.appendingPathComponent("project.pbxproj"))
        #expect(throws: ProjectLoadError.self) {
            _ = try XcodeProjectAdapter().load(at: fixture.projectURL)
        }
    }

    @Test
    func joinMatchesXcodeGroupRelativeResolution() {
        #expect(PBXProjDocument.join("/a/b", "c") == "/a/b/c")
        #expect(PBXProjDocument.join("/a/b", "../c") == "/a/c")
        #expect(PBXProjDocument.join("/a/b/", "./c") == "/a/b/c")
        #expect(PBXProjDocument.join("/a", "../../c") == "/c")
        #expect(PBXProjDocument.join("/a/b", "/etc/hosts") == "/etc/hosts")
        #expect(PBXProjDocument.join("/a/b", "") == "/a/b")
    }
}
