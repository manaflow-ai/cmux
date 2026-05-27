import AppKit
import CmuxExtensionKit
import Foundation
import UniformTypeIdentifiers

struct CmuxUserSwiftSidebarRecord: Codable, Equatable, Sendable {
    var sourcePath: String
    var sourceModificationTime: Date?
    var packageDirectoryPath: String
    var executablePath: String
    var descriptor: CmuxExtensionSidebarProviderDescriptor
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
            model.providerId = descriptor.id
            return model
        } catch {
            return Self.fallbackModel(
                descriptor: descriptor,
                snapshot: snapshot,
                message: error.localizedDescription
            )
        }
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

    private static func fallbackModel(
        descriptor: CmuxExtensionSidebarProviderDescriptor,
        snapshot: CmuxExtensionSidebarSnapshot,
        message: String
    ) -> CmuxExtensionSidebarRenderModel {
        let trimmed = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? String(localized: "sidebar.extension.swift.errorUnknown", defaultValue: "Swift sidebar failed.")
        let shortMessage = String(trimmed.prefix(180))
        let section = CmuxExtensionSidebarRenderSection(
            id: "swift-sidebar-error",
            treeSection: CmuxExtensionWorkspaceTreeSection(
                id: "swift-sidebar-error",
                title: String(localized: "sidebar.extension.swift.errorSection", defaultValue: "Swift Sidebar Error"),
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
        panel.title = String(localized: "sidebar.extension.swift.openPanel.title", defaultValue: "Load Swift Sidebar")
        panel.message = String(
            localized: "sidebar.extension.swift.openPanel.message",
            defaultValue: "Choose a Swift file that renders a CmuxExtensionKit sidebar."
        )
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if let swiftType = UTType(filenameExtension: "swift") {
            panel.allowedContentTypes = [swiftType]
        }

        panel.begin { response in
            guard response == .OK, let sourceURL = panel.url else { return }
            Task { @MainActor in
                await loadSource(sourceURL, defaults: defaults)
            }
        }
    }

    @MainActor
    static func reload(providerId: String, defaults: UserDefaults = .standard) {
        guard let existing = record(providerId: providerId, defaults: defaults) else { return }
        Task { @MainActor in
            await loadSource(URL(fileURLWithPath: existing.sourcePath), defaults: defaults)
        }
    }

    @MainActor
    static func remove(providerId: String, defaults: UserDefaults = .standard) {
        let remaining = records(defaults: defaults).filter { $0.descriptor.id != providerId }
        save(remaining, defaults: defaults)
        if defaults.string(forKey: CmuxExtensionSidebarSelection.defaultsKey) == providerId {
            CmuxExtensionSidebarSelection.setProviderId(CmuxExtensionSidebarSelection.defaultProviderId, defaults: defaults)
        }
    }

    @MainActor
    private static func loadSource(_ sourceURL: URL, defaults: UserDefaults) async {
        do {
            let record = try await Task.detached(priority: .userInitiated) {
                try CmuxUserSwiftSidebarBuilder.build(sourceURL: sourceURL)
            }.value
            upsert(record, defaults: defaults)
            CmuxExtensionSidebarSelection.setProviderId(record.descriptor.id, defaults: defaults)
        } catch {
            presentError(error)
        }
    }

    private static func upsert(_ record: CmuxUserSwiftSidebarRecord, defaults: UserDefaults) {
        var records = records(defaults: defaults)
        if let index = records.firstIndex(where: { $0.descriptor.id == record.descriptor.id }) {
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
            defaultValue: "Could Not Load Swift Sidebar"
        )
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.runModal()
    }
}

enum CmuxUserSwiftSidebarBuilder {
    static func build(sourceURL: URL) throws -> CmuxUserSwiftSidebarRecord {
        let sourceURL = sourceURL.standardizedFileURL
        guard sourceURL.pathExtension == "swift" else {
            throw CmuxUserSwiftSidebarError.invalidSourceExtension
        }
        guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            throw CmuxUserSwiftSidebarError.sourceUnavailable(sourceURL.path)
        }

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
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)

        let packagePath = try cmuxExtensionKitPackageURL()
        try writePackageManifest(packageDirectory: packageDirectory, cmuxExtensionKitPackageURL: packagePath)
        try copySource(sourceURL, into: targetDirectory)

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
                defaultValue: "Swift file"
            )
        }

        let sourceModificationTime = try? sourceURL
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate

        return CmuxUserSwiftSidebarRecord(
            sourcePath: sourceURL.path,
            sourceModificationTime: sourceModificationTime,
            packageDirectoryPath: packageDirectory.path,
            executablePath: executableURL.path,
            descriptor: descriptor
        )
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

    private static func copySource(_ sourceURL: URL, into targetDirectory: URL) throws {
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let fileName = source.contains("@main") ? "UserSidebar.swift" : "main.swift"
        let destination = targetDirectory.appendingPathComponent(fileName, isDirectory: false)
        try source.write(to: destination, atomically: true, encoding: .utf8)
        let staleFileName = fileName == "main.swift" ? "UserSidebar.swift" : "main.swift"
        let staleURL = targetDirectory.appendingPathComponent(staleFileName, isDirectory: false)
        if FileManager.default.fileExists(atPath: staleURL.path) {
            try FileManager.default.removeItem(at: staleURL)
        }
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
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        if let input {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            try process.run()
            stdinPipe.fileHandleForWriting.write(input)
            try? stdinPipe.fileHandleForWriting.close()
        } else {
            try process.run()
        }
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
    case invalidSourceExtension
    case sourceUnavailable(String)
    case cmuxExtensionKitUnavailable
    case executableMissing(String)
    case unexpectedResponse
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSourceExtension:
            return String(
                localized: "sidebar.extension.swift.error.invalidSourceExtension",
                defaultValue: "Choose a .swift file."
            )
        case .sourceUnavailable(let path):
            let format = String(
                localized: "sidebar.extension.swift.error.sourceUnavailable",
                defaultValue: "The Swift file could not be read: %@"
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
