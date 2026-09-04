@preconcurrency public import Foundation

/// External dependencies used by managed Chromium sessions.
///
/// The executable app constructs this value at its composition boundary. The
/// package never reaches into global filesystem, network, bundle, or process
/// state, which keeps the runtime independently testable.
public struct ChromiumBrowserRuntimeEnvironment: Sendable {
    // FileManager is documented thread-safe. Scope the escape hatch to this
    // immutable dependency rather than marking the environment unchecked.
    nonisolated(unsafe) let fileManager: FileManager
    let runtimeDownloadSession: URLSession
    let loopbackCDPSession: URLSession
    let applicationSupportURLProvider: @Sendable () -> URL?
    let bundleIdentifierProvider: @Sendable () -> String
    let executableOverrideProvider: @Sendable () -> URL?
    let startupDeadline: @Sendable () async throws -> Void

    /// Creates an explicit dependency environment for managed Chromium.
    ///
    /// - Parameters:
    ///   - fileManager: Filesystem implementation used for the managed cache and profiles.
    ///   - runtimeDownloadSession: Network session used for the pinned runtime download.
    ///   - loopbackCDPSession: No-proxy network session used only for loopback CDP.
    ///   - applicationSupportURLProvider: Provider for cmux's application-support root.
    ///   - bundleIdentifierProvider: Provider for the cmux-owned storage namespace.
    ///   - executableOverrideProvider: Optional local-development executable override.
    ///   - startupDeadline: Signal fired when a launched child's CDP handshake has taken too long.
    public init(
        fileManager: FileManager,
        runtimeDownloadSession: URLSession,
        loopbackCDPSession: URLSession,
        applicationSupportURLProvider: @escaping @Sendable () -> URL?,
        bundleIdentifierProvider: @escaping @Sendable () -> String,
        executableOverrideProvider: @escaping @Sendable () -> URL?,
        startupDeadline: @escaping @Sendable () async throws -> Void
    ) {
        self.fileManager = fileManager
        self.runtimeDownloadSession = runtimeDownloadSession
        self.loopbackCDPSession = loopbackCDPSession
        self.applicationSupportURLProvider = applicationSupportURLProvider
        self.bundleIdentifierProvider = bundleIdentifierProvider
        self.executableOverrideProvider = executableOverrideProvider
        self.startupDeadline = startupDeadline
    }
}
