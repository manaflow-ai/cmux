import CmuxNextCompat
public import CmuxNextRemoteView
public import Foundation

// In every configuration: the iPhone host streams the phone's browser tabs from it
// (Release builds bundle it too); the DEBUG "Open Remote Browser Tab" UI stays DEBUG.
/// The host's readiness line, `{"listening":"127.0.0.1:PORT"}`; nil for any
/// other line or a non-loopback address.
public nonisolated struct RemoteBrowserHostListening: Sendable, Equatable {
    public let endpoint: RemoteRdLoopbackEndpoint

    public init?(line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.blockingJSONObject(with: data) as? [String: Any],
              let address = object["listening"] as? String,
              address.hasPrefix("127.0.0.1:"),
              let port = UInt16(address.dropFirst("127.0.0.1:".count)),
              let loopback = RemoteRdLoopbackEndpoint(port: port) else { return nil }
        endpoint = loopback
    }
}

/// Finds the remote browser host: `CMUX_NEXT_RB_HOST` (a standalone host
/// `.app` or its executable), else the host this build embeds as a second
/// executable, `Contents/MacOS/cmux-remote-browser-host`. The host must run
/// from an app bundle that holds its CEF framework and helper apps: CEF loads
/// them relative to it, and the helpers' sandbox lets them read only that
/// bundle (scripts/cmux-next/remote-browser-host-layout.sh).
public nonisolated struct LocalRemoteBrowserHostLocator: Sendable {
    public static let environmentKey = "CMUX_NEXT_RB_HOST"
    public static let executableName = "cmux-remote-browser-host"
    /// The embedded host, relative to the app bundle.
    public static let bundledExecutablePath = "Contents/MacOS/\(executableName)"

    public let environment: [String: String]
    public let appBundle: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, appBundle: URL = Bundle.main.bundleURL) {
        self.environment = environment
        self.appBundle = appBundle
    }

    /// The candidates in order (the override first).
    public var candidates: [URL] {
        let override = environment[Self.environmentKey].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        return [override.map(Self.executable(in:)), appBundle.appending(path: Self.bundledExecutablePath)].compactMap { $0 }
    }

    /// The first candidate that is an executable file.
    public func executable() -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// A host `.app` names its executable; any other path is the executable.
    static func executable(in url: URL) -> URL {
        url.pathExtension == "app" ? url.appending(path: "Contents/MacOS/\(executableName)") : url
    }
}

