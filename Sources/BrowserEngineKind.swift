import Foundation
import AppKit
import CryptoKit
import SwiftUI

/// Which browser engine a new browser pane should be created with.
///
/// cmux ships with two browser engines that can be selected via the
/// **Debug → Browser Engine** menu:
///
/// - ``wkwebview`` — the default. Uses WebKit, the same engine Safari
///   ships. Production-tested, no separate process tree on macOS, but
///   no Chromium-extension support.
/// - ``cef`` — Chromium Embedded Framework Chrome runtime. Adds support
///   for Chrome extensions (MV3, popups, `chrome.storage`, etc.) at the
///   cost of an extra ~270 MiB framework + 5 helper processes per
///   cmux launch. **Experimental.** Requires the `CEF/` SwiftPM
///   package to be wired into the Xcode project; see
///   `CEF/INTEGRATION.md`.
///
/// The selection is stored in `UserDefaults` under
/// ``BrowserEngineKind/userDefaultsKey`` and applies to *newly created*
/// browser panes only. Existing panes keep the engine they were born
/// with. Switching the flag mid-session does not migrate panes.
public enum BrowserEngineKind: String, CaseIterable, Sendable {
    case wkwebview
    case cef

    /// `UserDefaults` key — also the `@AppStorage` key — used by the
    /// Debug menu toggle and by every code path that creates a new
    /// browser pane.
    public static let userDefaultsKey = "browser.engine.kind"

    /// Default for fresh installs and for unrecognised stored values.
    /// Always WKWebView; the CEF engine is opt-in.
    public static let `default`: BrowserEngineKind = .wkwebview

    /// The currently-active selection, resolved from `UserDefaults`.
    /// SwiftUI surfaces should prefer `@AppStorage(userDefaultsKey)`
    /// to participate in live updates; non-SwiftUI call sites can use
    /// this convenience accessor.
    public static var current: BrowserEngineKind {
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey)
        guard let raw, let kind = BrowserEngineKind(rawValue: raw) else {
            return .default
        }
        if kind == .cef {
            guard isCEFAvailable,
                  isCEFSupportedOnCurrentOS,
                  CEFRuntimeLocator.resolvedLocation() != nil else {
                return .default
            }
        }
        return kind
    }

    /// Whether the CEF engine is *available* in this build of cmux.
    /// True only when the `CMUXCEF` SwiftPM package is linked. cmux
    /// builds without the package compile fine but flip this to false
    /// so the Debug menu can grey out the option.
    public static var isCEFAvailable: Bool {
        #if canImport(CMUXCEF)
        return true
        #else
        return false
        #endif
    }

    /// Whether the current macOS version can run this CEF integration.
    /// Keep this aligned with `CEFEngine.start`, which rejects older
    /// macOS versions before booting Chromium.
    public static var isCEFSupportedOnCurrentOS: Bool {
        if #available(macOS 15.0, *) {
            return true
        } else {
            return false
        }
    }

    /// True only when CEF is linked and the current OS can run it.
    static var canSelectCEF: Bool {
        isCEFAvailable && isCEFSupportedOnCurrentOS
    }

    /// Human-readable label used by the Debug menu.
    public var displayLabel: String {
        switch self {
        case .wkwebview:
            return String(localized: "browserEngine.wkwebview.label", defaultValue: "WKWebView (default)")
        case .cef:
            return String(localized: "browserEngine.cef.label", defaultValue: "CEF - Chromium (experimental)")
        }
    }
}

struct CEFRuntimeDescriptor: Equatable, Sendable {
    let version: String
    let tarballName: String
    let tarballSHA1: String
    let tarballSizeBytes: Int64
    let extractedDirectoryName: String
    let sourceBaseURL: URL

    static var current: CEFRuntimeDescriptor {
        bundledLockfileDescriptor() ?? fallbackCurrent
    }

    private static let fallbackCurrent = CEFRuntimeDescriptor(
        version: "146.0.10+g8219561+chromium-146.0.7680.179",
        tarballName: "cef_binary_146.0.10+g8219561+chromium-146.0.7680.179_macosarm64.tar.bz2",
        tarballSHA1: "a483c800e506a592c63b60b36a12127eea3fc39f",
        tarballSizeBytes: 282_101_327,
        extractedDirectoryName: "cef_binary_146.0.10+g8219561+chromium-146.0.7680.179_macosarm64",
        sourceBaseURL: URL(string: "https://cef-builds.spotifycdn.com/")!
    )

    private static func bundledLockfileDescriptor(bundle: Bundle = .main) -> CEFRuntimeDescriptor? {
        guard let url = bundle.url(forResource: "cef.lock", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let lock = try? JSONDecoder().decode(CEFLockfile.self, from: data),
              let platform = lock.platforms["macosarm64"],
              let source = lock.sources.first,
              let baseURL = URL(string: source.baseURL) else {
            return nil
        }
        return CEFRuntimeDescriptor(
            version: lock.version,
            tarballName: platform.tarball,
            tarballSHA1: platform.sha1,
            tarballSizeBytes: platform.sizeBytes,
            extractedDirectoryName: platform.extractedDirectoryName,
            sourceBaseURL: baseURL
        )
    }

    var downloadURL: URL {
        sourceBaseURL.appendingPathComponent(tarballName)
    }

    static let requiredFreeBytes: Int64 = 2_500_000_000
}

private struct CEFLockfile: Decodable {
    struct Platform: Decodable {
        let tarball: String
        let sha1: String
        let sizeBytes: Int64
        let extractedDirectoryName: String

        private enum CodingKeys: String, CodingKey {
            case tarball
            case sha1
            case sizeBytes = "size_bytes"
            case extractedDirectoryName = "extracted_dir_name"
        }
    }

    struct Source: Decodable {
        let baseURL: String

        private enum CodingKeys: String, CodingKey {
            case baseURL = "base_url"
        }
    }

    let version: String
    let platforms: [String: Platform]
    let sources: [Source]
}

struct CEFRuntimeLocation: Equatable, Sendable {
    let versionRoot: URL
    let frameworksDirectory: URL

    var frameworkBinaryURL: URL {
        frameworksDirectory
            .appendingPathComponent("Chromium Embedded Framework.framework", isDirectory: true)
            .appendingPathComponent("Versions/A/Chromium Embedded Framework")
    }

    var helperExecutableURL: URL {
        frameworksDirectory
            .appendingPathComponent("cmux Helper.app", isDirectory: true)
            .appendingPathComponent("Contents/MacOS/cmux Helper")
    }

    var isUsable: Bool {
        FileManager.default.isExecutableFile(atPath: frameworkBinaryURL.path)
    }
}

enum CEFRuntimeLocator {
    static func applicationSupportRoot(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent(bundleIdentifier ?? "com.cmuxterm.app", isDirectory: true)
            .appendingPathComponent("CEFRuntime", isDirectory: true)
    }

    static func installedLocation(
        descriptor: CEFRuntimeDescriptor = .current,
        root: URL? = nil,
        fileManager: FileManager = .default
    ) -> CEFRuntimeLocation? {
        let runtimeRoot: URL
        if let root {
            runtimeRoot = root
        } else {
            guard let resolved = try? applicationSupportRoot(fileManager: fileManager) else {
                return nil
            }
            runtimeRoot = resolved
        }
        let versionRoot = runtimeRoot.appendingPathComponent(descriptor.version, isDirectory: true)
        let location = CEFRuntimeLocation(
            versionRoot: versionRoot,
            frameworksDirectory: versionRoot.appendingPathComponent("Frameworks", isDirectory: true)
        )
        return location.isUsable ? location : nil
    }

    static func bundledLocation(bundle: Bundle = .main) -> CEFRuntimeLocation? {
        let frameworksDirectory = bundle.bundleURL
            .appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let location = CEFRuntimeLocation(
            versionRoot: bundle.bundleURL,
            frameworksDirectory: frameworksDirectory
        )
        return location.isUsable ? location : nil
    }

    static func resolvedLocation() -> CEFRuntimeLocation? {
        installedLocation() ?? bundledLocation()
    }
}

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
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture(let architecture):
            return String(
                localized: "cefRuntime.installError.unsupportedArchitecture",
                defaultValue: "CEF runtime install is only configured for macOS arm64 right now. Current architecture: \(architecture)."
            )
        case .insufficientDiskSpace(let available, let required):
            return String(
                localized: "cefRuntime.installError.insufficientDiskSpace",
                defaultValue: "Not enough free disk space to install CEF. Available: \(Self.formatBytes(available)); required: \(Self.formatBytes(required))."
            )
        case .downloadedFileMissing:
            return String(
                localized: "cefRuntime.installError.downloadedFileMissing",
                defaultValue: "The CEF download did not produce a file."
            )
        case .downloadedFileSizeMismatch(let got, let expected):
            return String(
                localized: "cefRuntime.installError.downloadedFileSizeMismatch",
                defaultValue: "CEF download size mismatch. Got \(got) bytes, expected \(expected) bytes."
            )
        case .downloadedFileHashMismatch(let got, let expected):
            return String(
                localized: "cefRuntime.installError.downloadedFileHashMismatch",
                defaultValue: "CEF download SHA1 mismatch. Got \(got), expected \(expected)."
            )
        case .expectedExtractedDirectoryMissing(let path):
            return String(
                localized: "cefRuntime.installError.expectedExtractedDirectoryMissing",
                defaultValue: "The CEF archive did not contain the expected directory: \(path)."
            )
        case .expectedFrameworkMissing(let path):
            return String(
                localized: "cefRuntime.installError.expectedFrameworkMissing",
                defaultValue: "The installed CEF framework is missing: \(path)."
            )
        case .commandFailed(let message):
            return String(
                localized: "cefRuntime.installError.commandFailed",
                defaultValue: "CEF installer command failed: \(message)"
            )
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

@MainActor
final class CEFRuntimeInstaller: ObservableObject {
    static let shared = CEFRuntimeInstaller()

    @Published private(set) var phase: CEFRuntimeInstallPhase = .idle

    var isInstalledOrBundled: Bool {
        CEFRuntimeLocator.resolvedLocation() != nil
    }

    var menuStatusText: String? {
        guard BrowserEngineKind.isCEFSupportedOnCurrentOS else {
            return String(localized: "cefRuntime.menuStatus.unsupportedOS", defaultValue: "requires macOS 15.0")
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
        if isInstalledOrBundled {
            phase = .installed
            return true
        }
        guard !phase.isBusy else { return false }
        guard await confirmInstall(presentingWindow: presentingWindow) else {
            return false
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
            return true
        } catch {
            let message = error.localizedDescription
            progressPresenter.close()
            phase = .failed(message)
            presentFailure(message, presentingWindow: presentingWindow)
            return false
        }
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
        let actualSHA1 = try sha1Hex(of: fileURL)
        guard actualSHA1 == descriptor.tarballSHA1 else {
            throw CEFRuntimeInstallerError.downloadedFileHashMismatch(
                got: actualSHA1,
                expected: descriptor.tarballSHA1
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

        guard CEFRuntimeLocation(
            versionRoot: finalRoot,
            frameworksDirectory: finalRoot.appendingPathComponent("Frameworks", isDirectory: true)
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
        let delegate = CEFRuntimeDownloadDelegate(
            progressReporter: progressReporter
        )
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
                        "\(launchPath) \(arguments.joined(separator: " ")) failed with exit \(terminatedProcess.terminationStatus): \(text)"
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

    private nonisolated static func sha1Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
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

@MainActor
private final class CEFRuntimeInstallProgressPresenter {
    private weak var presentingWindow: NSWindow?
    private let window: NSWindow
    private let titleField: NSTextField
    private let detailField: NSTextField
    private let progressIndicator: NSProgressIndicator

    init(presentingWindow: NSWindow?) {
        self.presentingWindow = presentingWindow

        titleField = NSTextField(labelWithString: String(
            localized: "cefRuntime.progress.title",
            defaultValue: "Installing Chromium runtime"
        ))
        titleField.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleField.lineBreakMode = .byWordWrapping

        detailField = NSTextField(labelWithString: String(
            localized: "cefRuntime.progress.preparing",
            defaultValue: "Preparing download..."
        ))
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byWordWrapping

        progressIndicator = NSProgressIndicator()
        progressIndicator.isIndeterminate = true
        progressIndicator.style = .bar
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.controlSize = .regular

        let stack = NSStackView(views: [titleField, detailField, progressIndicator])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 380),
            progressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 140),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "cefRuntime.progress.windowTitle", defaultValue: "Chromium Runtime")
        window.contentView = contentView
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.cefRuntime.installProgress")
    }

    func show() {
        progressIndicator.startAnimation(nil)
        if let presentingWindow {
            presentingWindow.beginSheet(window, completionHandler: nil)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func update(phase: CEFRuntimeInstallPhase) {
        switch phase {
        case .downloading(let progress):
            titleField.stringValue = String(
                localized: "cefRuntime.progress.downloadingTitle",
                defaultValue: "Downloading Chromium runtime"
            )
            if let progress {
                progressIndicator.stopAnimation(nil)
                progressIndicator.isIndeterminate = false
                progressIndicator.doubleValue = min(max(progress, 0), 1) * 100
                detailField.stringValue = String(
                    format: String(localized: "cefRuntime.progress.downloadingPercent", defaultValue: "%.0f%% downloaded"),
                    min(max(progress, 0), 1) * 100
                )
            } else {
                progressIndicator.isIndeterminate = true
                progressIndicator.startAnimation(nil)
                detailField.stringValue = String(
                    localized: "cefRuntime.progress.downloading",
                    defaultValue: "Starting download..."
                )
            }
        case .installing:
            titleField.stringValue = String(
                localized: "cefRuntime.progress.installingTitle",
                defaultValue: "Installing Chromium runtime"
            )
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)
            detailField.stringValue = String(
                localized: "cefRuntime.progress.installing",
                defaultValue: "Verifying and installing files..."
            )
        case .idle, .installed, .failed:
            break
        }
    }

    func close() {
        if let sheetParent = window.sheetParent {
            sheetParent.endSheet(window)
        } else {
            window.close()
        }
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

    init(
        progressReporter: CEFRuntimeInstallProgressReporter?
    ) {
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
