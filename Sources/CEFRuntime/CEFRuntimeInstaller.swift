import AppKit
import CryptoKit
import Foundation
import Observation

enum CEFRuntimeInstallPhase: Equatable {
    case idle
    case downloading(progress: Double?)
    case installing
    case installed
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .downloading, .installing:
            return true
        case .idle, .installed, .failed:
            return false
        }
    }
}

enum CEFRuntimeInstallerError: LocalizedError, Equatable {
    case unsupportedArchitecture(String)
    case insufficientDiskSpace(available: Int64, required: Int64)
    case downloadedFileMissing
    case downloadedFileSizeMismatch(got: Int64, expected: Int64)
    case downloadedFileHashMismatch(got: String, expected: String)
    case expectedExtractedDirectoryMissing(String)
    case expectedFrameworkMissing(String)
    case expectedHelperMissing(String)
    case commandFailed(executable: String, status: Int32, output: String)

    var errorDescription: String? {
        userFacingMessage
    }

    var userFacingMessage: String {
        switch self {
        case .unsupportedArchitecture:
            return String(
                localized: "cefRuntime.installError.unsupportedArchitecture",
                defaultValue: "CEF runtime install is only configured for Apple Silicon Macs."
            )
        case .insufficientDiskSpace:
            return String(
                localized: "cefRuntime.installError.insufficientDiskSpace",
                defaultValue: "Not enough free disk space to install the Chromium runtime. Free disk space and try again."
            )
        case .downloadedFileMissing, .downloadedFileSizeMismatch, .downloadedFileHashMismatch:
            return String(
                localized: "cefRuntime.installError.integrityCheckFailed",
                defaultValue: "The Chromium runtime download could not be verified. Try again, or switch back to WKWebView."
            )
        case .expectedExtractedDirectoryMissing, .expectedFrameworkMissing, .expectedHelperMissing, .commandFailed:
            return String(
                localized: "cefRuntime.installError.installationFailed",
                defaultValue: "The Chromium runtime could not be installed. Try again, or switch back to WKWebView."
            )
        }
    }

    var diagnosticDescription: String {
        switch self {
        case .unsupportedArchitecture(let architecture):
            return "unsupportedArchitecture architecture=\(architecture)"
        case .insufficientDiskSpace(let available, let required):
            return "insufficientDiskSpace available=\(Self.formatBytes(available)) required=\(Self.formatBytes(required))"
        case .downloadedFileMissing:
            return "downloadedFileMissing"
        case .downloadedFileSizeMismatch(let got, let expected):
            return "downloadedFileSizeMismatch got=\(got) expected=\(expected)"
        case .downloadedFileHashMismatch(let got, let expected):
            return "downloadedFileHashMismatch algorithm=sha256 got=\(got) expected=\(expected)"
        case .expectedExtractedDirectoryMissing(let path):
            return "expectedExtractedDirectoryMissing path=\(path)"
        case .expectedFrameworkMissing(let path):
            return "expectedFrameworkMissing path=\(path)"
        case .expectedHelperMissing(let path):
            return "expectedHelperMissing path=\(path)"
        case .commandFailed(let executable, let status, let output):
            return "commandFailed executable=\(executable) status=\(status) output=\(output)"
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

@MainActor
@Observable
final class CEFRuntimeInstaller {
    static let shared = CEFRuntimeInstaller()

    private(set) var phase: CEFRuntimeInstallPhase = .idle
    @ObservationIgnored private var installWaiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private var hasActiveInstallRequest = false

    var isInstalledOrBundled: Bool {
        CEFRuntimeLocator.resolvedLocation() != nil
    }

    var menuStatusText: String? {
        guard BrowserEngineKind.isCEFSupportedOnCurrentOS else {
            return String(localized: "cefRuntime.menuStatus.unsupportedOS", defaultValue: "requires macOS 15.0")
        }
        guard BrowserEngineKind.isCEFSupportedOnCurrentArchitecture else {
            return String(
                localized: "cefRuntime.menuStatus.unsupportedArchitecture",
                defaultValue: "requires Apple Silicon"
            )
        }
        if isInstalledOrBundled { return nil }
        switch phase {
        case .idle:
            return String(localized: "cefRuntime.menuStatus.downloadsOnFirstUse", defaultValue: "downloads on first use")
        case .downloading(let progress):
            if let progress {
                return String(
                    format: String(localized: "cefRuntime.menuStatus.downloadingPercent", defaultValue: "downloading %.0f%%"),
                    Self.downloadPercentage(progress)
                )
            }
            return String(localized: "cefRuntime.menuStatus.downloading", defaultValue: "downloading...")
        case .installing:
            return String(localized: "cefRuntime.menuStatus.installing", defaultValue: "installing...")
        case .installed:
            return nil
        case .failed:
            return String(localized: "cefRuntime.menuStatus.installFailed", defaultValue: "install failed")
        }
    }

    func ensureInstalledAfterUserConfirmation(presentingWindow: NSWindow?) async -> Bool {
        guard BrowserEngineKind.isCEFSupportedOnCurrentOS else {
            presentFailure(
                String(
                    localized: "cefRuntime.installFailed.unsupportedOS",
                    defaultValue: "CEF requires macOS 15.0 or later."
                ),
                presentingWindow: presentingWindow
            )
            return false
        }
        guard BrowserEngineKind.isCEFSupportedOnCurrentArchitecture else {
            presentFailure(
                String(
                    localized: "cefRuntime.installFailed.unsupportedArchitecture",
                    defaultValue: "CEF currently requires an Apple Silicon Mac."
                ),
                presentingWindow: presentingWindow
            )
            return false
        }
        if isInstalledOrBundled {
            phase = .installed
            return true
        }
        if hasActiveInstallRequest {
            return await withCheckedContinuation { continuation in
                installWaiters.append(continuation)
            }
        }

        hasActiveInstallRequest = true
        if isInstalledOrBundled {
            phase = .installed
            return completeInstallRequest(true)
        }
        guard await confirmInstall(presentingWindow: presentingWindow) else {
            return completeInstallRequest(false)
        }

        let progressPresenter = CEFRuntimeInstallProgressPresenter(presentingWindow: presentingWindow)
        progressPresenter.show()

        do {
            updateInstallPhase(.downloading(progress: nil), progressPresenter: progressPresenter)
            let progressReporter = CEFRuntimeInstallProgressReporter { [weak self, weak progressPresenter] phase in
                self?.updateInstallPhase(phase, progressPresenter: progressPresenter)
            }
            try await Self.installRuntime(progressReporter: progressReporter)
            progressPresenter.close()
            phase = .installed
            return completeInstallRequest(true)
        } catch {
            let message: String
            if let installerError = error as? CEFRuntimeInstallerError {
                message = installerError.userFacingMessage
                #if DEBUG
                cmuxDebugLog("cef.runtime.install.failed \(installerError.diagnosticDescription)")
                #endif
            } else {
                message = String(
                    localized: "cefRuntime.installError.generic",
                    defaultValue: "The Chromium runtime could not be installed. Try again, or switch back to WKWebView."
                )
                #if DEBUG
                cmuxDebugLog("cef.runtime.install.failed unexpected=\(String(describing: error))")
                #endif
            }
            progressPresenter.close()
            phase = .failed(message)
            presentFailure(message, presentingWindow: presentingWindow)
            return completeInstallRequest(false)
        }
    }

    private func completeInstallRequest(_ result: Bool) -> Bool {
        hasActiveInstallRequest = false
        let waiters = installWaiters
        installWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: result)
        }
        return result
    }

    private func updateInstallPhase(
        _ newPhase: CEFRuntimeInstallPhase,
        progressPresenter: CEFRuntimeInstallProgressPresenter?
    ) {
        phase = newPhase
        progressPresenter?.update(phase: newPhase)
    }

    private func confirmInstall(presentingWindow: NSWindow?) async -> Bool {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = String(localized: "cefRuntime.installPrompt.title", defaultValue: "Install Chromium runtime?")
            alert.informativeText = String(
                localized: "cefRuntime.installPrompt.message",
                defaultValue: "cmux will download the pinned CEF runtime (~269 MB), verify it, and install it in Application Support. WKWebView remains available if this fails."
            )
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(localized: "cefRuntime.installPrompt.confirm", defaultValue: "Download and Install"))
            alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
            if let presentingWindow {
                alert.beginSheetModal(for: presentingWindow) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            } else {
                continuation.resume(returning: alert.runModal() == .alertFirstButtonReturn)
            }
        }
    }

    private func presentFailure(_ message: String, presentingWindow: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "cefRuntime.installFailed.title", defaultValue: "CEF runtime install failed")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        if let presentingWindow {
            alert.beginSheetModal(for: presentingWindow, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    static func installRuntime(
        descriptor: CEFRuntimeDescriptor = .current
    ) async throws {
        try await installRuntime(descriptor: descriptor, progressReporter: nil)
    }

    private static func installRuntime(
        descriptor: CEFRuntimeDescriptor = .current,
        progressReporter: CEFRuntimeInstallProgressReporter?
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try await installRuntimeInBackground(
                descriptor: descriptor,
                fileManager: .default,
                progressReporter: progressReporter
            )
        }.value
    }

    nonisolated static func hasEnoughDiskSpace(available: Int64, required: Int64) -> Bool {
        available >= required
    }

    nonisolated static func verifyTarballMetadata(
        fileURL: URL,
        descriptor: CEFRuntimeDescriptor,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw CEFRuntimeInstallerError.downloadedFileMissing
        }
        let size = try fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber
        if size?.int64Value != descriptor.tarballSizeBytes {
            throw CEFRuntimeInstallerError.downloadedFileSizeMismatch(
                got: size?.int64Value ?? -1,
                expected: descriptor.tarballSizeBytes
            )
        }
        let actualSHA256 = try sha256Hex(of: fileURL)
        guard actualSHA256 == descriptor.tarballSHA256 else {
            throw CEFRuntimeInstallerError.downloadedFileHashMismatch(
                got: actualSHA256,
                expected: descriptor.tarballSHA256
            )
        }
    }

    private nonisolated static func installRuntimeInBackground(
        descriptor: CEFRuntimeDescriptor,
        fileManager: FileManager,
        progressReporter: CEFRuntimeInstallProgressReporter?
    ) async throws {
        #if arch(arm64)
        #else
        throw CEFRuntimeInstallerError.unsupportedArchitecture(ProcessInfo.processInfo.machineArchitecture)
        #endif

        let runtimeRoot = try CEFRuntimeLocator.applicationSupportRoot(fileManager: fileManager)
        if CEFRuntimeLocator.installedLocation(descriptor: descriptor, root: runtimeRoot, fileManager: fileManager) != nil {
            return
        }

        try fileManager.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        let available = availableCapacity(for: runtimeRoot)
        if !hasEnoughDiskSpace(available: available, required: CEFRuntimeDescriptor.requiredFreeBytes) {
            throw CEFRuntimeInstallerError.insufficientDiskSpace(
                available: available,
                required: CEFRuntimeDescriptor.requiredFreeBytes
            )
        }

        let workRoot = runtimeRoot.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        let extractRoot = workRoot.appendingPathComponent("extract", isDirectory: true)
        let installRoot = workRoot.appendingPathComponent("runtime", isDirectory: true)
        defer { try? fileManager.removeItem(at: workRoot) }
        try fileManager.createDirectory(at: extractRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: installRoot, withIntermediateDirectories: true)

        let downloadURL = workRoot.appendingPathComponent(descriptor.tarballName)
        progressReporter?.report(.downloading(progress: nil))
        try await download(
            descriptor.downloadURL,
            to: downloadURL,
            fileManager: fileManager,
            progressReporter: progressReporter
        )
        progressReporter?.report(.installing)
        try verifyTarballMetadata(fileURL: downloadURL, descriptor: descriptor, fileManager: fileManager)
        try await runCommand("/usr/bin/tar", arguments: ["-xjf", downloadURL.path, "-C", extractRoot.path])

        let extracted = extractRoot.appendingPathComponent(descriptor.extractedDirectoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: extracted.path) else {
            throw CEFRuntimeInstallerError.expectedExtractedDirectoryMissing(extracted.path)
        }

        let frameworksDir = installRoot.appendingPathComponent("Frameworks", isDirectory: true)
        try fileManager.createDirectory(at: frameworksDir, withIntermediateDirectories: true)
        let sourceFramework = extracted
            .appendingPathComponent("Release", isDirectory: true)
            .appendingPathComponent("Chromium Embedded Framework.framework", isDirectory: true)
        let installedFramework = frameworksDir
            .appendingPathComponent("Chromium Embedded Framework.framework", isDirectory: true)
        guard fileManager.fileExists(atPath: sourceFramework.path) else {
            throw CEFRuntimeInstallerError.expectedFrameworkMissing(sourceFramework.path)
        }
        try await runCommand("/bin/cp", arguments: ["-R", sourceFramework.path, installedFramework.path])
        try await restructureFramework(installedFramework)

        let finalRoot = runtimeRoot.appendingPathComponent(descriptor.version, isDirectory: true)
        if fileManager.fileExists(atPath: finalRoot.path) {
            try fileManager.removeItem(at: finalRoot)
        }
        try fileManager.moveItem(at: installRoot, to: finalRoot)

        let helperExecutableURL = CEFRuntimeLocator.bundledHelperExecutableURL()
        guard fileManager.isExecutableFile(atPath: helperExecutableURL.path) else {
            throw CEFRuntimeInstallerError.expectedHelperMissing(helperExecutableURL.path)
        }
        guard CEFRuntimeLocation(
            versionRoot: finalRoot,
            frameworksDirectory: finalRoot.appendingPathComponent("Frameworks", isDirectory: true),
            helperExecutableURL: helperExecutableURL
        ).isUsable else {
            throw CEFRuntimeInstallerError.expectedFrameworkMissing(finalRoot.path)
        }
    }

    private nonisolated static func download(
        _ sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager,
        progressReporter: CEFRuntimeInstallProgressReporter?
    ) async throws {
        let delegate = CEFRuntimeDownloadDelegate(progressReporter: progressReporter)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (temporaryURL, _) = try await session.download(from: sourceURL, delegate: delegate)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }

    private nonisolated static func restructureFramework(_ frameworkURL: URL) async throws {
        let name = frameworkURL.deletingPathExtension().lastPathComponent
        let versions = frameworkURL.appendingPathComponent("Versions", isDirectory: true)
        let versionA = versions.appendingPathComponent("A", isDirectory: true)
        let binary = versionA.appendingPathComponent(name)
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: versionA.path) {
            try fileManager.createDirectory(at: versionA, withIntermediateDirectories: true)
            try fileManager.moveItem(
                at: frameworkURL.appendingPathComponent(name),
                to: binary
            )
            for child in ["Resources", "Libraries"] {
                let source = frameworkURL.appendingPathComponent(child, isDirectory: true)
                if fileManager.fileExists(atPath: source.path) {
                    try fileManager.moveItem(at: source, to: versionA.appendingPathComponent(child, isDirectory: true))
                }
            }
            try createOrReplaceSymlink(at: versions.appendingPathComponent("Current"), destination: "A")
            try createOrReplaceSymlink(at: frameworkURL.appendingPathComponent(name), destination: "Versions/Current/\(name)")
            try createOrReplaceSymlink(at: frameworkURL.appendingPathComponent("Resources"), destination: "Versions/Current/Resources")
            if fileManager.fileExists(atPath: versionA.appendingPathComponent("Libraries", isDirectory: true).path) {
                try createOrReplaceSymlink(at: frameworkURL.appendingPathComponent("Libraries"), destination: "Versions/Current/Libraries")
            }
        }

        try await runCommand("/usr/bin/install_name_tool", arguments: [
            "-id",
            "@rpath/\(name).framework/Versions/A/\(name)",
            binary.path
        ])
        _ = try? await runCommand("/usr/bin/codesign", arguments: ["--remove-signature", binary.path])
        try await runCommand("/usr/bin/codesign", arguments: [
            "--force",
            "--sign",
            "-",
            "--timestamp=none",
            binary.path
        ])
    }

    private nonisolated static func createOrReplaceSymlink(at url: URL, destination: String) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            try fileManager.removeItem(at: url)
        }
        try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
    }

    @discardableResult
    private nonisolated static func runCommand(_ launchPath: String, arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cef-command-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        process.standardOutput = outputHandle
        process.standardError = outputHandle

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { terminatedProcess in
                try? outputHandle.close()
                let data = (try? Data(contentsOf: outputURL)) ?? Data()
                try? FileManager.default.removeItem(at: outputURL)
                let text = String(data: data, encoding: .utf8) ?? ""
                guard terminatedProcess.terminationStatus == 0 else {
                    continuation.resume(throwing: CEFRuntimeInstallerError.commandFailed(
                        executable: launchPath,
                        status: terminatedProcess.terminationStatus,
                        output: text
                    ))
                    return
                }
                continuation.resume(returning: text)
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                try? outputHandle.close()
                try? FileManager.default.removeItem(at: outputURL)
                continuation.resume(throwing: error)
            }
        }
    }

    private nonisolated static func availableCapacity(for url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage {
            return Int64(important)
        }
        if let capacity = values?.volumeAvailableCapacity {
            return Int64(capacity)
        }
        return Int64.max
    }

    private nonisolated static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = handle.readData(ofLength: 1024 * 1024)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func downloadPercentage(_ progress: Double) -> Double {
        min(max(progress, 0), 1) * 100
    }
}

private final class CEFRuntimeInstallProgressReporter: @unchecked Sendable {
    private let reportOnMain: @MainActor (CEFRuntimeInstallPhase) -> Void

    init(reportOnMain: @escaping @MainActor (CEFRuntimeInstallPhase) -> Void) {
        self.reportOnMain = reportOnMain
    }

    func report(_ phase: CEFRuntimeInstallPhase) {
        Task { @MainActor in
            reportOnMain(phase)
        }
    }
}

private final class CEFRuntimeDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progressReporter: CEFRuntimeInstallProgressReporter?

    init(progressReporter: CEFRuntimeInstallProgressReporter?) {
        self.progressReporter = progressReporter
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressReporter?.report(.downloading(progress: progress))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}

private extension ProcessInfo {
    var machineArchitecture: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = Mirror(reflecting: systemInfo.machine)
        let bytes = machine.children.compactMap { child -> UInt8? in
            guard let value = child.value as? Int8, value != 0 else { return nil }
            return UInt8(bitPattern: value)
        }
        return String(bytes: bytes, encoding: .utf8) ?? "unknown"
    }
}
