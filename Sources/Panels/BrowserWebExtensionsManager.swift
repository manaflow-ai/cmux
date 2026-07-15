import Foundation
import WebKit

/// Loads Safari Web Extensions (WebExtension `manifest.json` bundles, the same
/// format Safari and Chrome use) into every cmux browser webview.
///
/// Extensions are installed from the native manager or by placing an unpacked
/// extension directory (or a `.zip` of one) in
/// `~/.config/cmux/browser-extensions/`. Each entry must contain a
/// `manifest.json` at its root. Manager installs load immediately; entries added
/// outside cmux are discovered at app launch.
///
/// Installing an extension into the directory is treated as consent: every
/// permission, host match pattern, and content-script match pattern the manifest
/// requests is granted at load, and runtime requests for optional permissions
/// are granted without prompting.
@available(macOS 15.4, *)
@MainActor
final class BrowserWebExtensionsManager: NSObject {
    private enum LoadWaiter {
        case pendingRegistration
        case waiting(CheckedContinuation<Void, Never>)
    }

    /// Fixed controller identifier so extension storage (`browser.storage`,
    /// declarativeNetRequest state) persists across launches.
    private static let controllerIdentifier = UUID(uuidString: "3B7D2A9E-5C41-4F8A-B6D0-9E2C7A51F3D8")!

    let controller: WKWebExtensionController
    let directory: URL
    var loadTask: Task<Void, Never>?
    private let directoryRepository = BrowserWebExtensionDirectoryRepository()
    private(set) var isLoaded = false
    private var loadWaiters: [UUID: LoadWaiter] = [:]
    private(set) var loadedContexts: [WKWebExtensionContext] = []
    private(set) var loadErrors: [(url: URL, error: any Error)] = []

    init(directory: URL, controllerConfiguration: WKWebExtensionController.Configuration? = nil) {
        self.directory = directory
        let configuration = controllerConfiguration
            ?? WKWebExtensionController.Configuration(identifier: Self.controllerIdentifier)
        self.controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
    }

    /// Directories and `.zip` archives directly inside `directory`. Hidden
    /// entries are skipped so `.DS_Store` and dotfiles never surface as errors.
    nonisolated static func candidateURLs(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { url in
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    return true
                }
                return url.pathExtension.lowercased() == "zip"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func startLoading() {
        guard loadTask == nil else { return }
        loadTask = Task { await loadExtensions() }
    }

    /// Suspends until the in-flight extension load finishes, bounded by
    /// `timeout` so a hung or pathologically slow load degrades to navigating
    /// without extensions instead of blocking every panel's first navigation
    /// forever. Returns immediately when loading already finished or never
    /// started.
    func waitUntilLoaded(
        timeout: Duration = .seconds(5),
        clock: any Clock<Duration> = ContinuousClock()
    ) async {
        guard !isLoaded, loadTask != nil else { return }
        let waiterID = UUID()
        loadWaiters[waiterID] = .pendingRegistration
        let timeoutTask = Task { @MainActor [weak self] in
            try? await clock.sleep(for: timeout, tolerance: nil)
            guard !Task.isCancelled else { return }
            self?.resumeLoadWaiter(waiterID)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard loadWaiters[waiterID] != nil else {
                    continuation.resume()
                    return
                }
                loadWaiters[waiterID] = .waiting(continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resumeLoadWaiter(waiterID)
            }
        }
        timeoutTask.cancel()
    }

    private func resumeLoadWaiter(_ id: UUID) {
        guard let waiter = loadWaiters.removeValue(forKey: id) else { return }
        if case let .waiting(continuation) = waiter {
            continuation.resume()
        }
    }

    private func resumeLoadWaiters() {
        let waiters = Array(loadWaiters.values)
        loadWaiters.removeAll()
        for waiter in waiters {
            if case let .waiting(continuation) = waiter {
                continuation.resume()
            }
        }
    }

    func loadExtensions() async {
        defer {
            isLoaded = true
            resumeLoadWaiters()
        }
        let candidates = await directoryRepository.candidateURLs(in: directory)
        guard !Task.isCancelled else { return }
        for url in candidates {
            guard !Task.isCancelled else { return }
            do {
                let context = try await loadExtension(at: url)
#if DEBUG
                cmuxDebugLog(
                    "browser.extensions.loaded name=\(context.webExtension.displayName ?? url.lastPathComponent) " +
                    "permissions=\(context.webExtension.requestedPermissions.count) " +
                    "patterns=\(context.webExtension.allRequestedMatchPatterns.count)"
                )
#endif
            } catch {
                loadErrors.append((url: url, error: error))
#if DEBUG
                cmuxDebugLog("browser.extensions.load-failed entry=\(url.lastPathComponent) error=\(error)")
#endif
            }
        }
    }

    func installExtension(from source: URL) async throws -> BrowserWebExtensionInstallReceipt {
        // Serialize installs after startup discovery so the same package cannot
        // be loaded once by each path when a user installs during app launch.
        await waitUntilLoaded()
        // Validate before copying. WKWebExtension accepts either a directory or
        // ZIP archive and parses the manifest plus referenced resources.
        _ = try await WKWebExtension(resourceBaseURL: source)
        let destination = try await directoryRepository.installCandidate(from: source, into: directory)
        do {
            let context = try await loadExtension(at: destination)
            return BrowserWebExtensionInstallReceipt(
                name: context.webExtension.displayName ?? destination.deletingPathExtension().lastPathComponent
            )
        } catch {
            await directoryRepository.removeInstalledCandidate(at: destination)
            throw error
        }
    }

    private func loadExtension(at url: URL) async throws -> WKWebExtensionContext {
        let webExtension = try await WKWebExtension(resourceBaseURL: url)
        let context = WKWebExtensionContext(for: webExtension)
        // Stable identifier derived from the install-directory name so
        // per-extension storage survives relaunches.
        context.uniqueIdentifier = "cmux-browser-extension-\(url.lastPathComponent)"
        context.isInspectable = true
        grantRequestedPermissions(in: context, for: webExtension)
        try controller.load(context)
        loadedContexts.append(context)
        return context
    }

    func presentationSnapshot() -> BrowserWebExtensionsPresentationSnapshot {
        BrowserWebExtensionsPresentationSnapshot(
            state: isLoaded ? .ready : .loading,
            extensions: loadedContexts.map { context in
                BrowserWebExtensionsPresentationSnapshot.Item(
                    id: context.uniqueIdentifier,
                    name: context.webExtension.displayName ?? context.uniqueIdentifier
                )
            },
            failures: loadErrors.map { failure in
                BrowserWebExtensionsPresentationSnapshot.Failure(
                    id: failure.url.path,
                    entryName: failure.url.lastPathComponent,
                    message: failure.error.localizedDescription
                )
            },
            directoryPath: directory.path
        )
    }

    private func grantRequestedPermissions(in context: WKWebExtensionContext, for webExtension: WKWebExtension) {
        for permission in webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in webExtension.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
    }
}

@available(macOS 15.4, *)
extension BrowserWebExtensionsManager: WKWebExtensionControllerDelegate {
    // Runtime permission requests are granted without prompting, but only for
    // what the manifest declares (`permissions`/`host_permissions` plus
    // `optional_permissions`/`optional_host_permissions`); installing the
    // extension is the consent gate for exactly that declared set. Anything
    // outside the manifest is denied.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        let declared = extensionContext.webExtension.requestedPermissions
            .union(extensionContext.webExtension.optionalPermissions)
        completionHandler(permissions.intersection(declared), nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        let declared = Self.declaredMatchPatterns(of: extensionContext.webExtension)
        let allowed = urls.filter { url in declared.contains { $0.matches(url) } }
        completionHandler(allowed, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        let declared = Self.declaredMatchPatterns(of: extensionContext.webExtension)
        let allowed = matchPatterns.filter { requested in declared.contains { $0.matches(requested) } }
        completionHandler(allowed, nil)
    }

    private static func declaredMatchPatterns(of webExtension: WKWebExtension) -> Set<WKWebExtension.MatchPattern> {
        webExtension.allRequestedMatchPatterns
            .union(webExtension.optionalPermissionMatchPatterns)
    }
}
