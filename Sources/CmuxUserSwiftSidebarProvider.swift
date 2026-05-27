import AppKit
import CmuxExtensionKit
import Foundation
import UniformTypeIdentifiers

struct CmuxUserSwiftSidebarRecord: Codable, Equatable, Sendable {
    var sourcePath: String
    var sourceKind: CmuxUserSwiftSidebarSourceKind?
    var sourceModificationTime: Date?
    var packageDirectoryPath: String
    var executablePath: String
    var descriptor: CmuxExtensionSidebarProviderDescriptor
}

enum CmuxUserSwiftSidebarSourceKind: String, Codable, Equatable, Sendable {
    case swiftFile
    case directory
}

struct CmuxUserSwiftSidebarSyncResult: Sendable {
    var records: [CmuxUserSwiftSidebarRecord]
    var failures: [CmuxUserSwiftSidebarSyncFailure]
}

struct CmuxUserSwiftSidebarSyncFailure: Sendable {
    var sourcePath: String
    var message: String
}

struct CmuxUserSwiftSidebarProvider: CmuxExtensionSidebarMutableProvider {
    let record: CmuxUserSwiftSidebarRecord

    var descriptor: CmuxExtensionSidebarProviderDescriptor {
        record.descriptor
    }

    func render(snapshot: CmuxExtensionSidebarSnapshot) -> CmuxExtensionSidebarRenderModel {
        render(snapshot: snapshot, context: .current)
    }

    func render(
        snapshot: CmuxExtensionSidebarSnapshot,
        context: CmuxExtensionSidebarRenderContext
    ) -> CmuxExtensionSidebarRenderModel {
        CmuxUserSwiftSidebarRenderCache.shared.render(record: record, snapshot: snapshot, context: context)
    }

    func handle(
        _ mutation: CmuxExtensionSidebarMutation,
        snapshot: CmuxExtensionSidebarSnapshot
    ) throws -> CmuxExtensionCommandResult {
        try CmuxUserSwiftSidebarProcess.run(
            executableURL: URL(fileURLWithPath: record.executablePath),
            request: .handle(mutation: mutation, snapshot: snapshot)
        ) { response in
            guard case .command(let result) = response else {
                throw CmuxUserSwiftSidebarError.unexpectedResponse
            }
            return result
        }
    }

    fileprivate static func fallbackModel(
        descriptor: CmuxExtensionSidebarProviderDescriptor,
        snapshot: CmuxExtensionSidebarSnapshot,
        message: String
    ) -> CmuxExtensionSidebarRenderModel {
        let trimmed = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? String(localized: "sidebar.extension.swift.errorUnknown", defaultValue: "Custom sidebar failed.")
        let shortMessage = String(trimmed.prefix(180))
        let section = CmuxExtensionSidebarRenderSection(
            id: "swift-sidebar-error",
            treeSection: CmuxExtensionWorkspaceTreeSection(
                id: "swift-sidebar-error",
                title: String(localized: "sidebar.extension.swift.errorSection", defaultValue: "Custom Sidebar Error"),
                subtitle: nil,
                systemImageName: "exclamationmark.triangle",
                projectRootPath: nil,
                workspaceIds: snapshot.workspaceIds
            ),
            rows: snapshot.workspaces.map { workspace in
                CmuxExtensionSidebarRenderRow(
                    id: workspace.id,
                    title: workspace.title,
                    workspaceId: workspace.id,
                    accessory: .inspector,
                    subtitle: .plain(shortMessage)
                )
            }
        )
        return CmuxExtensionSidebarRenderModel(
            providerId: descriptor.id,
            snapshotSequence: snapshot.sequence,
            sections: [section]
        )
    }
}

final class CmuxUserSwiftSidebarRenderCache: @unchecked Sendable {
    static let shared = CmuxUserSwiftSidebarRenderCache()
    static let didChangeNotification = Notification.Name("cmuxUserSwiftSidebarRenderCacheDidChange")

    private struct Key: Hashable, Sendable {
        var providerId: String
        var executablePath: String
        var sourceModificationTime: TimeInterval?
        var snapshotHash: String
    }

    private let lock = NSLock()
    private var models: [Key: CmuxExtensionSidebarRenderModel] = [:]
    private var previousModelsByProvider: [String: CmuxExtensionSidebarRenderModel] = [:]
    private var failures: [Key: String] = [:]
    private var inFlight: Set<Key> = []

    func render(
        record: CmuxUserSwiftSidebarRecord,
        snapshot: CmuxExtensionSidebarSnapshot,
        context: CmuxExtensionSidebarRenderContext
    ) -> CmuxExtensionSidebarRenderModel {
        let descriptor = record.descriptor
        let key: Key
        do {
            key = try makeKey(record: record, snapshot: snapshot)
        } catch {
            return CmuxUserSwiftSidebarProvider.fallbackModel(
                descriptor: descriptor,
                snapshot: snapshot,
                message: error.localizedDescription
            )
        }

        var shouldStartRender = false
        let cachedModel: CmuxExtensionSidebarRenderModel?
        let previousModel: CmuxExtensionSidebarRenderModel?
        let failureMessage: String?
        lock.lock()
        cachedModel = models[key]
        previousModel = previousModelsByProvider[descriptor.id]
        failureMessage = failures[key]
        if cachedModel == nil, failureMessage == nil, !inFlight.contains(key) {
            inFlight.insert(key)
            shouldStartRender = true
        }
        lock.unlock()

        if let cachedModel {
            return cachedModel
        }

        if shouldStartRender {
            startRender(record: record, snapshot: snapshot, context: context, key: key)
        }

        if let failureMessage {
            return CmuxUserSwiftSidebarProvider.fallbackModel(
                descriptor: descriptor,
                snapshot: snapshot,
                message: failureMessage
            )
        }

        if let previousModel, previousModel.snapshotSequence == snapshot.sequence {
            return previousModel
        }

        return Self.loadingModel(descriptor: descriptor, snapshot: snapshot)
    }

    func invalidate(providerId: String) {
        lock.lock()
        models = models.filter { $0.key.providerId != providerId }
        previousModelsByProvider.removeValue(forKey: providerId)
        failures = failures.filter { $0.key.providerId != providerId }
        inFlight = inFlight.filter { $0.providerId != providerId }
        lock.unlock()
    }

    private func makeKey(
        record: CmuxUserSwiftSidebarRecord,
        snapshot: CmuxExtensionSidebarSnapshot
    ) throws -> Key {
        let snapshotData = try JSONEncoder.cmuxExtensionSidebarExecutable.encode(snapshot)
        return Key(
            providerId: record.descriptor.id,
            executablePath: record.executablePath,
            sourceModificationTime: record.sourceModificationTime?.timeIntervalSinceReferenceDate,
            snapshotHash: Self.stableHash(snapshotData)
        )
    }

    private func startRender(
        record: CmuxUserSwiftSidebarRecord,
        snapshot: CmuxExtensionSidebarSnapshot,
        context: CmuxExtensionSidebarRenderContext,
        key: Key
    ) {
        Task.detached(priority: .userInitiated) {
            let result: Result<CmuxExtensionSidebarRenderModel, Error>
            do {
                var model: CmuxExtensionSidebarRenderModel = try CmuxUserSwiftSidebarProcess.run(
                    executableURL: URL(fileURLWithPath: record.executablePath),
                    request: .render(snapshot: snapshot, context: context)
                ) { response in
                    guard case .render(let model) = response else {
                        throw CmuxUserSwiftSidebarError.unexpectedResponse
                    }
                    return model
                }
                model.providerId = record.descriptor.id
                result = .success(model)
            } catch {
                result = .failure(error)
            }
            self.finishRender(key: key, providerId: record.descriptor.id, result: result)
        }
    }

    private func finishRender(
        key: Key,
        providerId: String,
        result: Result<CmuxExtensionSidebarRenderModel, Error>
    ) {
        lock.lock()
        inFlight.remove(key)
        switch result {
        case .success(let model):
            models[key] = model
            previousModelsByProvider[providerId] = model
            failures.removeValue(forKey: key)
        case .failure(let error):
            failures[key] = error.localizedDescription
        }
        lock.unlock()

        Task { @MainActor in
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    private static func loadingModel(
        descriptor: CmuxExtensionSidebarProviderDescriptor,
        snapshot: CmuxExtensionSidebarSnapshot
    ) -> CmuxExtensionSidebarRenderModel {
        let subtitle = String(localized: "sidebar.extension.swift.loadingSubtitle", defaultValue: "Rendering...")
        let section = CmuxExtensionSidebarRenderSection(
            id: "swift-sidebar-loading",
            treeSection: CmuxExtensionWorkspaceTreeSection(
                id: "swift-sidebar-loading",
                title: String(localized: "sidebar.extension.swift.loadingSection", defaultValue: "Loading Custom Sidebar"),
                subtitle: nil,
                systemImageName: "hourglass",
                projectRootPath: nil,
                workspaceIds: snapshot.workspaceIds
            ),
            rows: snapshot.workspaces.map { workspace in
                CmuxExtensionSidebarRenderRow(
                    id: workspace.id,
                    title: workspace.title,
                    workspaceId: workspace.id,
                    accessory: .inspector,
                    subtitle: .plain(subtitle)
                )
            }
        )
        return CmuxExtensionSidebarRenderModel(
            providerId: descriptor.id,
            snapshotSequence: snapshot.sequence,
            sections: [section]
        )
    }

    private static func stableHash(_ data: Data) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

enum CmuxUserSwiftSidebarRegistry {
    static let defaultsKey = "cmuxExtensionSidebar.swiftSourceRecords"
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func providers(defaults: UserDefaults = .standard) -> [any CmuxExtensionSidebarProvider] {
        records(defaults: defaults).map(CmuxUserSwiftSidebarProvider.init(record:))
    }

    static func records(defaults: UserDefaults = .standard) -> [CmuxUserSwiftSidebarRecord] {
        guard let data = defaults.data(forKey: defaultsKey),
              let records = try? decoder.decode([CmuxUserSwiftSidebarRecord].self, from: data) else {
            return []
        }
        return records
    }

    static func record(providerId: String, defaults: UserDefaults = .standard) -> CmuxUserSwiftSidebarRecord? {
        records(defaults: defaults).first { $0.descriptor.id == providerId }
    }

    @MainActor
    static func presentOpenPanelAndLoad(defaults: UserDefaults = .standard) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "sidebar.extension.swift.openPanel.title", defaultValue: "Load Custom Sidebar")
        panel.message = String(
            localized: "sidebar.extension.swift.openPanel.message",
            defaultValue: "Choose a Swift file or folder that renders a CmuxExtensionKit sidebar."
        )
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = try? CmuxUserSwiftSidebarBuilder.standardSourceRoot()
        if let swiftType = UTType(filenameExtension: "swift") {
            panel.allowedContentTypes = [swiftType, .folder]
        }

        panel.begin { response in
            guard response == .OK, let sourceURL = panel.url else { return }
            Task { @MainActor in
                await loadSource(sourceURL, defaults: defaults, replacingProviderId: nil)
            }
        }
    }

    @MainActor
    static func reload(providerId: String, defaults: UserDefaults = .standard) {
        guard let existing = record(providerId: providerId, defaults: defaults) else { return }
        Task { @MainActor in
            await loadSource(URL(fileURLWithPath: existing.sourcePath), defaults: defaults, replacingProviderId: providerId)
        }
    }

    @MainActor
    static func remove(providerId: String, defaults: UserDefaults = .standard) {
        let remaining = records(defaults: defaults).filter { $0.descriptor.id != providerId }
        save(remaining, defaults: defaults)
        CmuxUserSwiftSidebarRenderCache.shared.invalidate(providerId: providerId)
        if defaults.string(forKey: CmuxExtensionSidebarSelection.defaultsKey) == providerId {
            CmuxExtensionSidebarSelection.setProviderId(CmuxExtensionSidebarSelection.defaultProviderId, defaults: defaults)
        }
    }

    @MainActor
    static func loadSourceForCLI(_ sourceURL: URL, defaults: UserDefaults = .standard) async throws -> CmuxUserSwiftSidebarRecord {
        let record = try await Task.detached(priority: .userInitiated) {
            try CmuxUserSwiftSidebarBuilder.build(sourceURL: sourceURL)
        }.value
        upsert(record, replacingProviderId: nil, defaults: defaults)
        CmuxExtensionSidebarSelection.setProviderId(record.descriptor.id, defaults: defaults)
        return record
    }

    @MainActor
    static func syncStandardSourceDirectoryForCLI(defaults: UserDefaults = .standard) async throws -> CmuxUserSwiftSidebarSyncResult {
        let sourceURLs = try CmuxUserSwiftSidebarBuilder.standardSourceCandidates()
        var loadedRecords: [CmuxUserSwiftSidebarRecord] = []
        var failures: [CmuxUserSwiftSidebarSyncFailure] = []

        for sourceURL in sourceURLs {
            do {
                let record = try await Task.detached(priority: .userInitiated) {
                    try CmuxUserSwiftSidebarBuilder.build(sourceURL: sourceURL)
                }.value
                upsert(record, replacingProviderId: nil, defaults: defaults)
                loadedRecords.append(record)
            } catch {
                failures.append(
                    CmuxUserSwiftSidebarSyncFailure(
                        sourcePath: sourceURL.path,
                        message: error.localizedDescription
                    )
                )
            }
        }

        if let selectedProviderId = defaults.string(forKey: CmuxExtensionSidebarSelection.defaultsKey),
           loadedRecords.contains(where: { $0.descriptor.id == selectedProviderId }) {
            return CmuxUserSwiftSidebarSyncResult(records: loadedRecords, failures: failures)
        }

        if let firstRecord = loadedRecords.first {
            CmuxExtensionSidebarSelection.setProviderId(firstRecord.descriptor.id, defaults: defaults)
        }

        return CmuxUserSwiftSidebarSyncResult(records: loadedRecords, failures: failures)
    }

    @MainActor
    private static func loadSource(
        _ sourceURL: URL,
        defaults: UserDefaults,
        replacingProviderId: String?
    ) async {
        do {
            let record = try await Task.detached(priority: .userInitiated) {
                try CmuxUserSwiftSidebarBuilder.build(sourceURL: sourceURL)
            }.value
            upsert(record, replacingProviderId: replacingProviderId, defaults: defaults)
            CmuxExtensionSidebarSelection.setProviderId(record.descriptor.id, defaults: defaults)
        } catch {
            presentError(error)
        }
    }

    private static func upsert(
        _ record: CmuxUserSwiftSidebarRecord,
        replacingProviderId: String?,
        defaults: UserDefaults
    ) {
        if let replacingProviderId, replacingProviderId != record.descriptor.id {
            CmuxUserSwiftSidebarRenderCache.shared.invalidate(providerId: replacingProviderId)
        }
        CmuxUserSwiftSidebarRenderCache.shared.invalidate(providerId: record.descriptor.id)
        var records = records(defaults: defaults)
        if let replacingProviderId,
           let index = records.firstIndex(where: { $0.descriptor.id == replacingProviderId }) {
            records[index] = record
        } else if let index = records.firstIndex(where: { $0.descriptor.id == record.descriptor.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        save(records, defaults: defaults)
    }

    private static func save(_ records: [CmuxUserSwiftSidebarRecord], defaults: UserDefaults) {
        guard let data = try? encoder.encode(records) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    @MainActor
    private static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "sidebar.extension.swift.loadFailed.title",
            defaultValue: "Could Not Load Custom Sidebar"
        )
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.runModal()
    }
}

enum CmuxUserSwiftSidebarBuilder {
    static func build(sourceURL: URL) throws -> CmuxUserSwiftSidebarRecord {
        let preparedSource = try prepareSource(sourceURL.standardizedFileURL)
        let sourceURL = preparedSource.url

        let sourceHash = stableHash(sourceURL.path)
        let packageDirectory = try buildRoot()
            .appendingPathComponent(sourceHash, isDirectory: true)
            .appendingPathComponent("Package", isDirectory: true)
        let scratchDirectory = try buildRoot()
            .appendingPathComponent(sourceHash, isDirectory: true)
            .appendingPathComponent("Build", isDirectory: true)
        let targetDirectory = packageDirectory
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("CmuxUserSidebarExtension", isDirectory: true)
        if FileManager.default.fileExists(atPath: packageDirectory.path) {
            try FileManager.default.removeItem(at: packageDirectory)
        }
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)

        let packagePath = try cmuxExtensionKitPackageURL()
        try writePackageManifest(packageDirectory: packageDirectory, cmuxExtensionKitPackageURL: packagePath)
        try copySource(preparedSource, into: targetDirectory)

        _ = try CmuxUserSwiftSidebarProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "swift",
                "build",
                "-c",
                "release",
                "--package-path",
                packageDirectory.path,
                "--scratch-path",
                scratchDirectory.path,
                "--product",
                "CmuxUserSidebarExtension",
            ],
            input: nil
        )

        let binPathResult = try CmuxUserSwiftSidebarProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "swift",
                "build",
                "-c",
                "release",
                "--package-path",
                packageDirectory.path,
                "--scratch-path",
                scratchDirectory.path,
                "--show-bin-path",
            ],
            input: nil
        )
        let binPath = String(data: binPathResult.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        let executableURL = URL(fileURLWithPath: binPath, isDirectory: true)
            .appendingPathComponent("CmuxUserSidebarExtension", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CmuxUserSwiftSidebarError.executableMissing(executableURL.path)
        }

        var descriptor: CmuxExtensionSidebarProviderDescriptor = try CmuxUserSwiftSidebarProcess.run(
            executableURL: executableURL,
            request: .descriptor
        ) { response in
            guard case .descriptor(let descriptor) = response else {
                throw CmuxUserSwiftSidebarError.unexpectedResponse
            }
            return descriptor
        }
        descriptor.id = descriptor.id.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "cmux.userSwift.\(sourceHash)"
        descriptor.isHostProvided = false
        if descriptor.subtitle == nil {
            descriptor.subtitle = CmuxExtensionLocalizedText(
                key: "sidebar.extension.swift.descriptorSubtitle",
                defaultValue: "Custom sidebar"
            )
        }

        let sourceModificationTime = try latestModificationDate(for: preparedSource)

        return CmuxUserSwiftSidebarRecord(
            sourcePath: sourceURL.path,
            sourceKind: preparedSource.kind,
            sourceModificationTime: sourceModificationTime,
            packageDirectoryPath: packageDirectory.path,
            executablePath: executableURL.path,
            descriptor: descriptor
        )
    }

    static func standardSourceRoot() throws -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("sidebars", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func standardSourceRootDisplayPath() -> String {
        "~/.config/cmux/sidebars"
    }

    static func standardSourceCandidates() throws -> [URL] {
        let root = try standardSourceRoot()
        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        return children.compactMap { child -> URL? in
            let name = child.lastPathComponent
            guard !name.hasPrefix("."),
                  !excludedSourcePathComponents.contains(name) else {
                return nil
            }
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else {
                return nil
            }
            if values.isDirectory == true {
                return child.standardizedFileURL
            }
            guard values.isRegularFile == true,
                  child.pathExtension == "swift",
                  name != "Package.swift" else {
                return nil
            }
            return child.standardizedFileURL
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func buildRoot() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let root = base
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("SwiftSidebarExtensions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func cmuxExtensionKitPackageURL() throws -> URL {
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("CmuxExtensionKit", isDirectory: true)
            .standardizedFileURL
        if let bundled, packageExists(at: bundled) {
            return bundled
        }

        #if DEBUG
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePackage = sourceRoot
            .appendingPathComponent("Packages", isDirectory: true)
            .appendingPathComponent("CmuxExtensionKit", isDirectory: true)
            .standardizedFileURL
        if packageExists(at: sourcePackage) {
            return sourcePackage
        }
        #endif

        throw CmuxUserSwiftSidebarError.cmuxExtensionKitUnavailable
    }

    private static func packageExists(at url: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: url.appendingPathComponent("Package.swift", isDirectory: false).path
        )
    }

    private static func writePackageManifest(
        packageDirectory: URL,
        cmuxExtensionKitPackageURL: URL
    ) throws {
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "CmuxUserSidebarExtension",
            platforms: [.macOS(.v14)],
            products: [
                .executable(name: "CmuxUserSidebarExtension", targets: ["CmuxUserSidebarExtension"]),
            ],
            dependencies: [
                .package(path: \(swiftStringLiteral(cmuxExtensionKitPackageURL.path))),
            ],
            targets: [
                .executableTarget(
                    name: "CmuxUserSidebarExtension",
                    dependencies: ["CmuxExtensionKit"]
                ),
            ]
        )
        """
        try manifest.write(
            to: packageDirectory.appendingPathComponent("Package.swift", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    private struct PreparedSource {
        var url: URL
        var kind: CmuxUserSwiftSidebarSourceKind
    }

    private static func prepareSource(_ sourceURL: URL) throws -> PreparedSource {
        let kind = try sourceKind(for: sourceURL)
        let standardizedRoot = try standardSourceRoot()
        if isDescendant(sourceURL, of: standardizedRoot) {
            return PreparedSource(url: sourceURL, kind: kind)
        }

        let importedURL = try importSource(sourceURL, kind: kind, into: standardizedRoot)
        return PreparedSource(url: importedURL, kind: kind)
    }

    private static func sourceKind(for sourceURL: URL) throws -> CmuxUserSwiftSidebarSourceKind {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw CmuxUserSwiftSidebarError.sourceUnavailable(sourceURL.path)
        }
        if isDirectory.boolValue {
            guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
                throw CmuxUserSwiftSidebarError.sourceUnavailable(sourceURL.path)
            }
            return .directory
        }
        guard sourceURL.pathExtension == "swift" else {
            throw CmuxUserSwiftSidebarError.invalidSource
        }
        guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            throw CmuxUserSwiftSidebarError.sourceUnavailable(sourceURL.path)
        }
        return .swiftFile
    }

    private static func importSource(
        _ sourceURL: URL,
        kind: CmuxUserSwiftSidebarSourceKind,
        into root: URL
    ) throws -> URL {
        let sourceName = sourceURL.deletingPathExtension().lastPathComponent.nilIfEmpty
            ?? sourceURL.lastPathComponent.nilIfEmpty
            ?? "sidebar"
        let targetDirectory = root
            .appendingPathComponent("\(safePathComponent(sourceName))-\(stableHash(sourceURL.path))", isDirectory: true)
        if FileManager.default.fileExists(atPath: targetDirectory.path) {
            try FileManager.default.removeItem(at: targetDirectory)
        }
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        switch kind {
        case .swiftFile:
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let fileName = source.contains("@main") ? "UserSidebar.swift" : "main.swift"
            let destination = targetDirectory.appendingPathComponent(fileName, isDirectory: false)
            try source.write(to: destination, atomically: true, encoding: .utf8)
            return destination
        case .directory:
            let swiftFiles = try swiftSourceFiles(in: sourceURL)
            guard !swiftFiles.isEmpty else {
                throw CmuxUserSwiftSidebarError.noSwiftSources(sourceURL.path)
            }
            for sourceFile in swiftFiles {
                let relative = relativePath(from: sourceURL, to: sourceFile)
                let destination = targetDirectory.appendingPathComponent(relative, isDirectory: false)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: sourceFile, to: destination)
            }
            return targetDirectory
        }
    }

    private static func copySource(_ preparedSource: PreparedSource, into targetDirectory: URL) throws {
        switch preparedSource.kind {
        case .swiftFile:
            let source = try String(contentsOf: preparedSource.url, encoding: .utf8)
            let fileName = source.contains("@main") ? "UserSidebar.swift" : "main.swift"
            let destination = targetDirectory.appendingPathComponent(fileName, isDirectory: false)
            try source.write(to: destination, atomically: true, encoding: .utf8)
        case .directory:
            let swiftFiles = try swiftSourceFiles(in: preparedSource.url)
            guard !swiftFiles.isEmpty else {
                throw CmuxUserSwiftSidebarError.noSwiftSources(preparedSource.url.path)
            }
            try validateDirectoryEntrypoint(sourceURL: preparedSource.url, swiftFiles: swiftFiles)
            for sourceFile in swiftFiles {
                let relative = relativePath(from: preparedSource.url, to: sourceFile)
                let destination = targetDirectory.appendingPathComponent(relative, isDirectory: false)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: sourceFile, to: destination)
            }
        }
    }

    private static func validateDirectoryEntrypoint(sourceURL: URL, swiftFiles: [URL]) throws {
        var hasMainSwift = false
        var hasAtMain = false
        for file in swiftFiles {
            if file.lastPathComponent == "main.swift" {
                hasMainSwift = true
            }
            let source = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            if source.contains("@main") {
                hasAtMain = true
            }
        }
        guard hasMainSwift || hasAtMain else {
            throw CmuxUserSwiftSidebarError.missingEntryPoint(sourceURL.path)
        }
    }

    private static func latestModificationDate(for preparedSource: PreparedSource) throws -> Date? {
        switch preparedSource.kind {
        case .swiftFile:
            return try? preparedSource.url
                .resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
        case .directory:
            return try swiftSourceFiles(in: preparedSource.url)
                .compactMap {
                    try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                }
                .max()
        }
    }

    private static func swiftSourceFiles(in directoryURL: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw CmuxUserSwiftSidebarError.sourceUnavailable(directoryURL.path)
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            if excludedSourcePathComponents.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true,
                  fileURL.pathExtension == "swift",
                  name != "Package.swift" else {
                continue
            }
            files.append(fileURL.standardizedFileURL)
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static let excludedSourcePathComponents: Set<String> = [
        ".build",
        ".git",
        ".swiftpm",
        "DerivedData"
    ]

    private static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func relativePath(from root: URL, to fileURL: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return fileURL.lastPathComponent
    }

    private static func safePathComponent(_ raw: String) -> String {
        let sanitized = raw.replacingOccurrences(
            of: #"[^\p{L}\p{N}._-]+"#,
            with: "-",
            options: .regularExpression
        )
        let trimmed = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.nilIfEmpty ?? "sidebar"
    }

    private static func swiftStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

enum CmuxUserSwiftSidebarProcess {
    struct Result: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    static func run<T>(
        executableURL: URL,
        request: CmuxExtensionSidebarExecutableRequest,
        decode: (CmuxExtensionSidebarExecutableResponse) throws -> T
    ) throws -> T {
        let input = try JSONEncoder.cmuxExtensionSidebarExecutable.encode(request)
        let result = try run(executableURL: executableURL, arguments: [], input: input)
        guard result.status == 0 else {
            throw CmuxUserSwiftSidebarError.processFailed(result.errorText)
        }
        let response = try JSONDecoder.cmuxExtensionSidebarExecutable.decode(
            CmuxExtensionSidebarExecutableResponse.self,
            from: result.stdout
        )
        if case .failure(let message) = response {
            throw CmuxUserSwiftSidebarError.processFailed(message)
        }
        return try decode(response)
    }

    static func run(
        executableURL: URL,
        arguments: [String],
        input: Data?
    ) throws -> Result {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-swift-sidebar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let stdoutURL = tempDirectory.appendingPathComponent("stdout", isDirectory: false)
        let stderrURL = tempDirectory.appendingPathComponent("stderr", isDirectory: false)
        let stdinURL = tempDirectory.appendingPathComponent("stdin", isDirectory: false)
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        if let input {
            try input.write(to: stdinURL)
        }
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        let stdinHandle = input == nil ? nil : try FileHandle(forReadingFrom: stdinURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            try? stdinHandle?.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        if input != nil {
            process.standardInput = stdinHandle
        }
        try process.run()
        process.waitUntilExit()

        try stdoutHandle.synchronize()
        try stderrHandle.synchronize()
        return Result(
            status: process.terminationStatus,
            stdout: (try? Data(contentsOf: stdoutURL)) ?? Data(),
            stderr: (try? Data(contentsOf: stderrURL)) ?? Data()
        )
    }
}

enum CmuxUserSwiftSidebarError: LocalizedError {
    case invalidSource
    case sourceUnavailable(String)
    case noSwiftSources(String)
    case missingEntryPoint(String)
    case cmuxExtensionKitUnavailable
    case executableMissing(String)
    case unexpectedResponse
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSource:
            return String(
                localized: "sidebar.extension.swift.error.invalidSourceExtension",
                defaultValue: "Choose a .swift file or a folder of Swift files."
            )
        case .sourceUnavailable(let path):
            let format = String(
                localized: "sidebar.extension.swift.error.sourceUnavailable",
                defaultValue: "The Swift source could not be read: %@"
            )
            return String.localizedStringWithFormat(format, path)
        case .noSwiftSources(let path):
            let format = String(
                localized: "sidebar.extension.swift.error.noSwiftSources",
                defaultValue: "No Swift source files were found in %@."
            )
            return String.localizedStringWithFormat(format, path)
        case .missingEntryPoint(let path):
            let format = String(
                localized: "sidebar.extension.swift.error.missingEntryPoint",
                defaultValue: "The custom sidebar folder at %@ needs a main.swift file or an @main entry point."
            )
            return String.localizedStringWithFormat(format, path)
        case .cmuxExtensionKitUnavailable:
            return String(
                localized: "sidebar.extension.swift.error.kitUnavailable",
                defaultValue: "CmuxExtensionKit was not available in this cmux build."
            )
        case .executableMissing(let path):
            let format = String(
                localized: "sidebar.extension.swift.error.executableMissing",
                defaultValue: "The Swift sidebar executable was not created at %@."
            )
            return String.localizedStringWithFormat(format, path)
        case .unexpectedResponse:
            return String(
                localized: "sidebar.extension.swift.error.unexpectedResponse",
                defaultValue: "The Swift sidebar returned an unexpected response."
            )
        case .processFailed(let message):
            return message.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? String(localized: "sidebar.extension.swift.error.processFailed", defaultValue: "The Swift sidebar process failed.")
        }
    }
}

private extension CmuxUserSwiftSidebarProcess.Result {
    var errorText: String {
        let stderrText = String(data: stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stderrText, !stderrText.isEmpty {
            return stderrText
        }
        let stdoutText = String(data: stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stdoutText ?? ""
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
