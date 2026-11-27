import Foundation

/// ``ProjectAdapter`` implementation that reads Xcode project bundles with Foundation.
///
/// Parses a `.xcworkspace` or `.xcodeproj` URL into a ``ProjectModel`` whose
/// modules, navigator groups, files, target memberships, and target summaries
/// match what Xcode shows in its Project Navigator and Targets list. The
/// adapter is read-only and intentionally avoids running `xcodebuild` so that
/// loading a project is fast (~3-30 ms on cmux's own project) and side-effect
/// free.
///
/// Use cases the adapter does **not** cover yet, and that callers should
/// degrade gracefully on:
///
/// - Cross-project dependencies (`PBXContainerItemProxy` with a non-local
///   `containerPortal`) are recorded as missing dependencies rather than
///   followed.
/// - Xcode 16+ `PBXFileSystemSynchronizedRootGroup` is rendered as a single
///   folder node and the adapter walks the on-disk directory to enumerate
///   children; per-target membership exception sets are not yet applied.
/// - Build settings, schemes, and `.xcconfig` resolution are deliberately
///   out of scope for this adapter; later additions to ``ProjectModel`` will
///   surface them through additional types populated by separate code paths.
public struct XcodeProjectAdapter: ProjectAdapter, Sendable {
    public let kind: ProjectAdapterKind = .xcode

    public init() {}

    public func canLoad(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "xcworkspace" || ext == "xcodeproj" { return true }
        return Self.findFirstProjectArtifact(in: url) != nil
    }

    public func load(at url: URL) throws -> ProjectModel {
        let resolved = try Self.resolveRoot(url)
        switch resolved.pathExtension.lowercased() {
        case "xcworkspace":
            return try loadWorkspace(at: resolved)
        case "xcodeproj":
            return try loadStandaloneProject(at: resolved)
        default:
            throw ProjectLoadError.unsupported(resolved)
        }
    }

    // MARK: - Workspace and project loading

    private func loadWorkspace(at workspaceURL: URL) throws -> ProjectModel {
        let workspace: XcodeWorkspaceFile
        do {
            workspace = try XcodeWorkspaceFile(workspaceURL: workspaceURL)
        } catch {
            throw ProjectLoadError.parseFailure(workspaceURL, reason: String(describing: error))
        }
        let projectURLs = workspace.fileURLs.filter { $0.pathExtension.lowercased() == "xcodeproj" }
        var modules: [ProjectModule] = []
        modules.reserveCapacity(projectURLs.count)
        for projectURL in projectURLs {
            if let module = try? loadModule(at: projectURL) {
                modules.append(module)
            }
        }
        return ProjectModel(
            id: ProjectModelID(rawValue: workspaceURL.standardizedFileURL.path),
            displayName: workspaceURL.deletingPathExtension().lastPathComponent,
            rootURL: workspaceURL,
            adapter: .xcode,
            modules: modules
        )
    }

    private func loadStandaloneProject(at projectURL: URL) throws -> ProjectModel {
        let module = try loadModule(at: projectURL)
        return ProjectModel(
            id: ProjectModelID(rawValue: projectURL.standardizedFileURL.path),
            displayName: projectURL.deletingPathExtension().lastPathComponent,
            rootURL: projectURL,
            adapter: .xcode,
            modules: [module]
        )
    }

    private func loadModule(at projectURL: URL) throws -> ProjectModule {
        let document: PBXProjDocument
        do {
            document = try PBXProjDocument(contentsOf: projectURL.appendingPathComponent("project.pbxproj"))
        } catch {
            throw ProjectLoadError.parseFailure(projectURL, reason: String(describing: error))
        }
        let projectID = document.rootObjectID
        guard let mainGroup = document.reference("mainGroup", of: projectID) else {
            throw ProjectLoadError.parseFailure(projectURL, reason: "missing mainGroup")
        }
        let sourceRoot = projectURL.deletingLastPathComponent().path
        let targetIDs = document.references("targets", of: projectID)
        let targets = Self.collectTargets(in: document, targetIDs: targetIDs, sourceRoot: sourceRoot)
        let memberships = Self.buildMembershipIndex(in: document, targetIDs: targetIDs)
        let moduleID = ProjectModuleID(rawValue: projectURL.standardizedFileURL.path)
        let rootGroup = Self.buildGroup(
            from: mainGroup,
            in: document,
            moduleID: moduleID,
            displayPath: "",
            sourceRoot: sourceRoot,
            memberships: memberships
        )
        let configurations = Self.collectBuildConfigurations(
            in: document,
            targetIDs: targetIDs,
            sourceRoot: sourceRoot
        )
        let schemes = Self.collectSchemes(
            projectURL: projectURL,
            in: document,
            targetIDs: targetIDs
        )
        return ProjectModule(
            id: moduleID,
            displayName: projectURL.deletingPathExtension().lastPathComponent,
            rootURL: projectURL,
            rootGroup: rootGroup,
            targets: targets,
            configurations: configurations,
            schemes: schemes
        )
    }

    private static func collectBuildConfigurations(
        in document: PBXProjDocument,
        targetIDs: [String],
        sourceRoot: String
    ) -> [BuildConfigSummary] {
        func summaries(of ownerID: String, scope: BuildConfigScope) -> [BuildConfigSummary] {
            document.buildConfigurations(of: ownerID).map { config in
                BuildConfigSummary(
                    id: BuildConfigID(rawValue: config),
                    name: document.string("name", of: config) ?? "",
                    scope: scope,
                    baseConfigurationPath: baseConfigurationURL(of: config, in: document, sourceRoot: sourceRoot),
                    rawSettings: normalizeRawSettings(document.buildSettings(of: config))
                )
            }
        }
        var out = summaries(of: document.rootObjectID, scope: .project)
        for target in targetIDs where document.isa(target) == "PBXNativeTarget" {
            out.append(contentsOf: summaries(of: target, scope: .target(TargetID(rawValue: target))))
        }
        return out
    }

    private static func baseConfigurationURL(
        of configurationID: String,
        in document: PBXProjDocument,
        sourceRoot: String
    ) -> URL? {
        document.reference("baseConfigurationReference", of: configurationID)
            .flatMap { document.fullPath(of: $0, sourceRoot: sourceRoot) }
            .map { URL(fileURLWithPath: $0) }
    }

    private static func normalizeRawSettings(_ source: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(source.count)
        for (key, value) in source {
            if let stringValue = value as? String {
                out[key] = stringValue
            } else if let arrayValue = value as? [String] {
                out[key] = arrayValue.joined(separator: " ")
            } else {
                out[key] = String(describing: value)
            }
        }
        return out
    }

    private static func collectSchemes(
        projectURL: URL,
        in document: PBXProjDocument,
        targetIDs: [String]
    ) -> [SchemeSummary] {
        var targetNameToID: [String: TargetID] = [:]
        for target in targetIDs {
            guard let name = document.string("name", of: target), targetNameToID[name] == nil else { continue }
            targetNameToID[name] = TargetID(rawValue: target)
        }
        var seen: Set<String> = []
        var out: [SchemeSummary] = []
        func append(_ schemes: [XcodeSchemeFile], shared: Bool) {
            for scheme in schemes where seen.insert(scheme.name).inserted {
                out.append(schemeSummary(from: scheme, shared: shared, targetNameToID: targetNameToID))
            }
        }
        append(
            XcodeSchemeFile.schemes(in: projectURL.appendingPathComponent("xcshareddata/xcschemes")),
            shared: true
        )
        let userDataRoot = projectURL.appendingPathComponent("xcuserdata")
        let userDirectories = ((try? FileManager.default.contentsOfDirectory(
            at: userDataRoot,
            includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.pathExtension == "xcuserdatad" }
            .sorted { $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8) }
        for directory in userDirectories {
            append(XcodeSchemeFile.schemes(in: directory.appendingPathComponent("xcschemes")), shared: false)
        }
        return out
    }

    private static func schemeSummary(
        from scheme: XcodeSchemeFile,
        shared: Bool,
        targetNameToID: [String: TargetID]
    ) -> SchemeSummary {
        let knownTargetIDValues = Set(targetNameToID.values.map(\.rawValue))
        func resolve(_ ref: XcodeSchemeFile.TargetReference) -> TargetID? {
            if let name = ref.blueprintName, let direct = targetNameToID[name] {
                return direct
            }
            if let blueprintUUID = ref.blueprintIdentifier,
               knownTargetIDValues.contains(blueprintUUID) {
                return TargetID(rawValue: blueprintUUID)
            }
            return nil
        }
        return SchemeSummary(
            id: SchemeID(rawValue: scheme.name),
            name: scheme.name,
            isShared: shared,
            runTargetIDs: scheme.runTarget.flatMap(resolve).map { [$0] } ?? [],
            testTargetIDs: scheme.testTargets.compactMap(resolve),
            profileTargetID: scheme.profileTarget.flatMap(resolve),
            archiveTargetID: scheme.archiveTarget.flatMap(resolve),
            launchArguments: scheme.launchArguments,
            environmentVariables: scheme.environmentVariables
        )
    }

    // MARK: - Group tree walk

    private static func buildGroup(
        from group: String,
        in document: PBXProjDocument,
        moduleID: ProjectModuleID,
        displayPath: String,
        sourceRoot: String,
        memberships: MembershipIndex
    ) -> ProjectGroup {
        let resolvedPath = document.fullPath(of: group, sourceRoot: sourceRoot)
        let groupName = document.string("name", of: group) ?? document.string("path", of: group) ?? "(group)"
        let childDisplayPath = displayPath.isEmpty ? groupName : "\(displayPath)/\(groupName)"
        var children: [ProjectNodeKind] = []
        for child in document.references("children", of: group) {
            switch document.isa(child) {
            case "PBXGroup", "PBXVariantGroup", "XCVersionGroup":
                children.append(.group(buildGroup(
                    from: child,
                    in: document,
                    moduleID: moduleID,
                    displayPath: childDisplayPath,
                    sourceRoot: sourceRoot,
                    memberships: memberships
                )))
            case "PBXFileSystemSynchronizedRootGroup":
                children.append(.group(buildSynchronizedGroup(
                    from: child,
                    in: document,
                    moduleID: moduleID,
                    displayPath: childDisplayPath,
                    sourceRoot: sourceRoot
                )))
            case "PBXFileReference":
                children.append(.file(buildFileNode(
                    from: child,
                    in: document,
                    moduleID: moduleID,
                    displayPath: childDisplayPath,
                    sourceRoot: sourceRoot,
                    memberships: memberships
                )))
            default:
                continue
            }
        }
        let nodeID = ProjectNodeID(rawValue: nodeIdentifier(
            moduleID: moduleID,
            displayPath: childDisplayPath,
            kind: "group"
        ))
        return ProjectGroup(
            id: nodeID,
            displayName: groupName,
            resolvedPath: resolvedPath.map { URL(fileURLWithPath: $0) },
            style: document.isa(group) == "PBXVariantGroup" ? .variant : .logical,
            children: children
        )
    }

    private static func buildSynchronizedGroup(
        from group: String,
        in document: PBXProjDocument,
        moduleID: ProjectModuleID,
        displayPath: String,
        sourceRoot: String
    ) -> ProjectGroup {
        let name = document.string("name", of: group) ?? document.string("path", of: group) ?? "(synchronized)"
        let childDisplayPath = displayPath.isEmpty ? name : "\(displayPath)/\(name)"
        let resolvedURL = document.fullPath(of: group, sourceRoot: sourceRoot).map { URL(fileURLWithPath: $0) }
        var children: [ProjectNodeKind] = []
        if let resolvedURL,
           let walker = try? FileManager.default.contentsOfDirectory(
               at: resolvedURL,
               includingPropertiesForKeys: [.isDirectoryKey],
               options: [.skipsHiddenFiles]
           ) {
            for url in walker.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    children.append(.group(buildFilesystemGroup(
                        at: url,
                        moduleID: moduleID,
                        displayPath: childDisplayPath
                    )))
                } else {
                    let nodeID = ProjectNodeID(rawValue: nodeIdentifier(
                        moduleID: moduleID,
                        displayPath: childDisplayPath + "/" + url.lastPathComponent,
                        kind: "file"
                    ))
                    children.append(.file(ProjectFileNode(
                        id: nodeID,
                        displayName: url.lastPathComponent,
                        resolvedPath: url,
                        fileType: nil,
                        existsOnDisk: true,
                        memberships: []
                    )))
                }
            }
        }
        let id = ProjectNodeID(rawValue: nodeIdentifier(
            moduleID: moduleID,
            displayPath: childDisplayPath,
            kind: "group"
        ))
        return ProjectGroup(
            id: id,
            displayName: name,
            resolvedPath: resolvedURL,
            style: .synchronized,
            children: children
        )
    }

    private static func buildFilesystemGroup(
        at url: URL,
        moduleID: ProjectModuleID,
        displayPath: String
    ) -> ProjectGroup {
        let name = url.lastPathComponent
        let childDisplayPath = "\(displayPath)/\(name)"
        var children: [ProjectNodeKind] = []
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for child in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                children.append(.group(buildFilesystemGroup(
                    at: child,
                    moduleID: moduleID,
                    displayPath: childDisplayPath
                )))
            } else {
                let id = ProjectNodeID(rawValue: nodeIdentifier(
                    moduleID: moduleID,
                    displayPath: childDisplayPath + "/" + child.lastPathComponent,
                    kind: "file"
                ))
                children.append(.file(ProjectFileNode(
                    id: id,
                    displayName: child.lastPathComponent,
                    resolvedPath: child,
                    fileType: nil,
                    existsOnDisk: true,
                    memberships: []
                )))
            }
        }
        let id = ProjectNodeID(rawValue: nodeIdentifier(
            moduleID: moduleID,
            displayPath: childDisplayPath,
            kind: "group"
        ))
        return ProjectGroup(
            id: id,
            displayName: name,
            resolvedPath: url,
            style: .synchronized,
            children: children
        )
    }

    private static func buildFileNode(
        from ref: String,
        in document: PBXProjDocument,
        moduleID: ProjectModuleID,
        displayPath: String,
        sourceRoot: String,
        memberships: MembershipIndex
    ) -> ProjectFileNode {
        let name = document.string("name", of: ref) ?? document.string("path", of: ref) ?? "(file)"
        let childDisplayPath = displayPath.isEmpty ? name : "\(displayPath)/\(name)"
        let url = document.fullPath(of: ref, sourceRoot: sourceRoot).map { URL(fileURLWithPath: $0) }
        let exists: Bool = {
            guard let url else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }()
        let nodeID = ProjectNodeID(rawValue: nodeIdentifier(
            moduleID: moduleID,
            displayPath: childDisplayPath,
            kind: "file"
        ))
        let fileMemberships = memberships.memberships(forFileUUID: ref)
        return ProjectFileNode(
            id: nodeID,
            displayName: name,
            resolvedPath: url,
            fileType: document.string("lastKnownFileType", of: ref) ?? document.string("explicitFileType", of: ref),
            existsOnDisk: exists,
            memberships: fileMemberships
        )
    }

    // MARK: - Target summaries

    private static func collectTargets(
        in document: PBXProjDocument,
        targetIDs: [String],
        sourceRoot: String
    ) -> [TargetSummary] {
        let projectXcconfigSettings = mergedXcconfigSettings(
            of: document.rootObjectID,
            in: document,
            sourceRoot: sourceRoot
        )
        return targetIDs.compactMap { target -> TargetSummary? in
            guard document.isa(target) == "PBXNativeTarget" else { return nil }
            let productType = document.string("productType", of: target)
                .map(TargetProductType.fromXcodeProductType) ?? .other
            let resolved = resolveTargetMetadata(
                target: target,
                in: document,
                projectXcconfig: projectXcconfigSettings,
                targetXcconfig: mergedXcconfigSettings(of: target, in: document, sourceRoot: sourceRoot)
            )
            let deps = document.references("dependencies", of: target).compactMap { dep -> TargetID? in
                if let resolved = document.reference("target", of: dep) {
                    return TargetID(rawValue: resolved)
                }
                if let proxy = document.reference("targetProxy", of: dep),
                   let info = document.string("remoteInfo", of: proxy) {
                    return TargetID(rawValue: "remote:\(info)")
                }
                return nil
            }
            return TargetSummary(
                id: TargetID(rawValue: target),
                displayName: document.string("name", of: target) ?? "",
                productType: productType,
                platforms: resolved.platforms,
                bundleIdentifier: resolved.bundleIdentifier,
                deploymentTarget: resolved.deploymentTarget,
                dependencies: deps
            )
        }
    }

    private static func mergedXcconfigSettings(
        of ownerID: String,
        in document: PBXProjDocument,
        sourceRoot: String
    ) -> [String: String] {
        var merged: [String: String] = [:]
        for config in document.buildConfigurations(of: ownerID) {
            guard let url = baseConfigurationURL(of: config, in: document, sourceRoot: sourceRoot),
                  let parsed = try? XcconfigParser.parse(at: url) else { continue }
            for (key, value) in parsed {
                merged[key] = value
            }
        }
        return merged
    }

    private struct ResolvedTargetMetadata {
        let bundleIdentifier: String?
        let deploymentTarget: String?
        let platforms: [String]
    }

    private static func resolveTargetMetadata(
        target: String,
        in document: PBXProjDocument,
        projectXcconfig: [String: String],
        targetXcconfig: [String: String]
    ) -> ResolvedTargetMetadata {
        let bundle = resolveSetting(
            key: "PRODUCT_BUNDLE_IDENTIFIER",
            target: target,
            in: document,
            projectXcconfig: projectXcconfig,
            targetXcconfig: targetXcconfig
        )
        let deploymentKeys = [
            "MACOSX_DEPLOYMENT_TARGET",
            "IPHONEOS_DEPLOYMENT_TARGET",
            "TVOS_DEPLOYMENT_TARGET",
            "WATCHOS_DEPLOYMENT_TARGET",
            "VISIONOS_DEPLOYMENT_TARGET"
        ]
        var deployment: String?
        for key in deploymentKeys {
            if let value = resolveSetting(
                key: key,
                target: target,
            in: document,
                projectXcconfig: projectXcconfig,
                targetXcconfig: targetXcconfig
            ), !value.isEmpty {
                deployment = value
                break
            }
        }
        var platforms: Set<String> = []
        if let supported = resolveSetting(
            key: "SUPPORTED_PLATFORMS",
            target: target,
            in: document,
            projectXcconfig: projectXcconfig,
            targetXcconfig: targetXcconfig
        ) {
            for piece in supported.split(separator: " ") {
                platforms.insert(String(piece))
            }
        }
        if let sdk = resolveSetting(
            key: "SDKROOT",
            target: target,
            in: document,
            projectXcconfig: projectXcconfig,
            targetXcconfig: targetXcconfig
        ) {
            platforms.insert(sdk)
        }
        return ResolvedTargetMetadata(
            bundleIdentifier: bundle,
            deploymentTarget: deployment,
            platforms: platforms.sorted()
        )
    }

    private static func resolveSetting(
        key: String,
        target: String,
        in document: PBXProjDocument,
        projectXcconfig: [String: String],
        targetXcconfig: [String: String]
    ) -> String? {
        for config in document.buildConfigurations(of: target) {
            if let raw = document.buildSettings(of: config)[key], let value = stringFromAny(raw), !value.isEmpty {
                return value
            }
        }
        if let value = targetXcconfig[key], !value.isEmpty { return value }
        if let value = projectXcconfig[key], !value.isEmpty { return value }
        return nil
    }

    private static func stringFromAny(_ value: Any) -> String? {
        if let s = value as? String { return s }
        if let a = value as? [String] { return a.joined(separator: " ") }
        return nil
    }

    // MARK: - Membership index

    private struct MembershipIndex {
        private let table: [String: [TargetMembership]]

        init(table: [String: [TargetMembership]]) {
            self.table = table
        }

        func memberships(forFileUUID uuid: String) -> [TargetMembership] {
            table[uuid] ?? []
        }
    }

    private static func buildMembershipIndex(in document: PBXProjDocument, targetIDs: [String]) -> MembershipIndex {
        var table: [String: [TargetMembership]] = [:]
        for target in targetIDs {
            let targetID = TargetID(rawValue: target)
            for phase in document.references("buildPhases", of: target) {
                let role = role(forPhaseKind: document.isa(phase))
                for buildFile in document.references("files", of: phase) {
                    guard let fileUUID = document.reference("fileRef", of: buildFile) else { continue }
                    let settings = document.objects[buildFile]?["settings"] as? [String: Any]
                    let flags = (settings?["COMPILER_FLAGS"] as? String)
                        .map { $0.split(separator: " ").map(String.init) }
                        ?? []
                    table[fileUUID, default: []].append(
                        TargetMembership(targetID: targetID, role: role, compilerFlags: flags)
                    )
                }
            }
        }
        return MembershipIndex(table: table)
    }

    private static func role(forPhaseKind isa: String?) -> TargetMembershipRole {
        switch isa {
        case "PBXSourcesBuildPhase": return .compile
        case "PBXFrameworksBuildPhase": return .framework
        case "PBXHeadersBuildPhase": return .header
        case "PBXCopyFilesBuildPhase": return .copy
        case "PBXShellScriptBuildPhase": return .script
        default: return .resource
        }
    }

    // MARK: - URL and path resolution

    private static func resolveRoot(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        let ext = standardized.pathExtension.lowercased()
        if ext == "xcworkspace" || ext == "xcodeproj" {
            guard FileManager.default.fileExists(atPath: standardized.path) else {
                throw ProjectLoadError.unreadable(standardized)
            }
            return standardized
        }
        guard let candidate = findFirstProjectArtifact(in: standardized) else {
            throw ProjectLoadError.unsupported(standardized)
        }
        return candidate
    }

    private static func findFirstProjectArtifact(in url: URL) -> URL? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        if let ws = contents.first(where: { $0.pathExtension.lowercased() == "xcworkspace" }) {
            return ws
        }
        return contents.first(where: { $0.pathExtension.lowercased() == "xcodeproj" })
    }

    private static func nodeIdentifier(
        moduleID: ProjectModuleID,
        displayPath: String,
        kind: String
    ) -> String {
        "\(moduleID.rawValue)|\(kind)|\(displayPath)"
    }
}
