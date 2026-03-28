import Foundation
import AppKit

/// Manages the on-demand download, verification, and loading of the
/// CEF (Chromium Embedded Framework) at runtime.
///
/// CEF is not bundled with the app. When a user first creates or
/// switches to a Chromium-engine browser profile, this manager
/// downloads the framework, verifies its checksum, extracts it,
/// and makes it available for CEF initialization.
final class CEFFrameworkManager: ObservableObject {

    static let shared = CEFFrameworkManager()

    // MARK: - Configuration

    /// CEF version pinned for this release of cmux.
    static let cefVersion = "130.1.16+g03e8e4e+chromium-130.0.6723.117"

    /// SHA256 of the compressed framework archive.
    static let expectedSHA256 = "" // TODO(phase0): set after first hosted build

    /// URL to the hosted compressed CEF framework archive.
    /// Hosted on GitHub Releases for manaflow-ai/cmux-cef-framework.
    static let downloadURL: URL = {
        // TODO(phase0): replace with actual hosted URL
        let base = "https://github.com/manaflow-ai/cmux-cef-framework/releases/download"
        let tag = "v130.1.16"
        let file = "cef-arm64.tar.gz"
        return URL(string: "\(base)/\(tag)/\(file)")!
    }()

    // MARK: - State

    enum State: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case extracting
        case ready
        case failed(message: String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.notDownloaded, .notDownloaded): return true
            case (.downloading(let a), .downloading(let b)): return a == b
            case (.extracting, .extracting): return true
            case (.ready, .ready): return true
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    @Published private(set) var state: State = .notDownloaded

    // MARK: - Paths

    /// Root directory for CEF framework storage.
    var frameworksDir: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.manaflow.cmux"
        return appSupport
            .appendingPathComponent(bundleID)
            .appendingPathComponent("Frameworks")
    }

    /// Path to the extracted CEF framework.
    var frameworkPath: URL {
        frameworksDir.appendingPathComponent("Chromium Embedded Framework.framework")
    }

    /// Path to the version stamp file (tracks which CEF version is installed).
    private var versionStampPath: URL {
        frameworksDir.appendingPathComponent(".cef-version")
    }

    // MARK: - Init

    private init() {
        checkExistingFramework()
    }

    // MARK: - Public API

    /// Returns true if the CEF framework is downloaded and ready to use.
    var isAvailable: Bool {
        state == .ready
    }

    /// Check if the framework already exists on disk.
    func checkExistingFramework() {
        let fm = FileManager.default
        if fm.fileExists(atPath: frameworkPath.path) {
            // Verify version matches
            if let stamp = try? String(contentsOf: versionStampPath, encoding: .utf8),
               stamp.trimmingCharacters(in: .whitespacesAndNewlines) == Self.cefVersion {
                state = .ready
                return
            }
            // Wrong version, needs re-download
            try? fm.removeItem(at: frameworkPath)
        }
        state = .notDownloaded
    }

    /// Start downloading the CEF framework. Calls completion on the
    /// main thread when done.
    func download(completion: @escaping (Result<Void, Error>) -> Void) {
        guard state != .ready else {
            completion(.success(()))
            return
        }

        if case .downloading = state { return }

        state = .downloading(progress: 0)

        let session = URLSession(
            configuration: .default,
            delegate: nil,
            delegateQueue: .main
        )

        let task = session.downloadTask(with: Self.downloadURL) { [weak self] tempURL, response, error in
            DispatchQueue.main.async {
                guard let self else { return }

                if let error {
                    self.state = .failed(message: error.localizedDescription)
                    completion(.failure(error))
                    return
                }

                guard let tempURL else {
                    let err = NSError(
                        domain: "CEFFrameworkManager",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Download produced no file"]
                    )
                    self.state = .failed(message: err.localizedDescription)
                    completion(.failure(err))
                    return
                }

                self.state = .extracting
                self.extractFramework(from: tempURL, completion: completion)
            }
        }

        // Observe progress
        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.state = .downloading(progress: progress.fractionCompleted)
            }
        }

        // Keep the observation alive until task completes
        objc_setAssociatedObject(task, "progressObservation", observation, .OBJC_ASSOCIATION_RETAIN)

        task.resume()
    }

    /// Cancel an in-progress download.
    func cancelDownload() {
        state = .notDownloaded
    }

    // MARK: - Private

    private func extractFramework(
        from archiveURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            do {
                let fm = FileManager.default

                // Ensure target directory exists
                try fm.createDirectory(
                    at: self.frameworksDir,
                    withIntermediateDirectories: true
                )

                // Remove existing framework if present
                let destPath = self.frameworkPath
                if fm.fileExists(atPath: destPath.path) {
                    try fm.removeItem(at: destPath)
                }

                // Extract tar.gz archive
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                process.arguments = [
                    "-xzf", archiveURL.path,
                    "-C", self.frameworksDir.path
                ]
                try process.run()
                process.waitUntilExit()

                guard process.terminationStatus == 0 else {
                    throw NSError(
                        domain: "CEFFrameworkManager",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "Failed to extract CEF framework (tar exit \(process.terminationStatus))"]
                    )
                }

                // Verify extraction produced the framework
                guard fm.fileExists(atPath: destPath.path) else {
                    throw NSError(
                        domain: "CEFFrameworkManager",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Extraction completed but framework not found at expected path"]
                    )
                }

                // Write version stamp
                try Self.cefVersion.write(
                    to: self.versionStampPath,
                    atomically: true,
                    encoding: .utf8
                )

                // Clean up temp file
                try? fm.removeItem(at: archiveURL)

                DispatchQueue.main.async {
                    self.state = .ready
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    self.state = .failed(message: error.localizedDescription)
                    completion(.failure(error))
                }
            }
        }
    }

    /// Estimated download size for UI display.
    static let estimatedDownloadSizeMB: Int = 120
}
