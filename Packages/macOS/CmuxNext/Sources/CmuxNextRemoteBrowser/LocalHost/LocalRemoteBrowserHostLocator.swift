public import CmuxNextRemoteView
public import Foundation

#if DEBUG
/// The host's readiness line, `{"listening":"127.0.0.1:PORT"}`; nil for any
/// other line or a non-loopback address.
public nonisolated struct RemoteBrowserHostListening: Sendable, Equatable {
    public let endpoint: RemoteRdLoopbackEndpoint

    public init?(line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let address = object["listening"] as? String,
              address.hasPrefix("127.0.0.1:"),
              let record = RemoteBrowserTabRecord(address: address) else { return nil }
        endpoint = record.endpoint
    }
}

/// Finds the remote browser host: `CMUX_NEXT_RB_HOST` (a host `.app` or its
/// executable), else the host app this build bundles at
/// `Contents/Helpers/cmux-remote-browser-host.app`. The host must run from an
/// app bundle: CEF loads its framework and helper apps relative to it
/// (scripts/cmux-next/bundle-remote-browser-host.sh makes that layout).
public nonisolated struct LocalRemoteBrowserHostLocator: Sendable {
    public static let environmentKey = "CMUX_NEXT_RB_HOST"
    public static let bundledAppPath = "Contents/Helpers/cmux-remote-browser-host.app"
    public static let executableName = "cmux-remote-browser-host"

    public let environment: [String: String]
    public let appBundle: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, appBundle: URL = Bundle.main.bundleURL) {
        self.environment = environment
        self.appBundle = appBundle
    }

    /// The candidates in order (the override first).
    public var candidates: [URL] {
        let override = environment[Self.environmentKey].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        return [override, appBundle.appending(path: Self.bundledAppPath)].compactMap { $0 }.map(Self.executable(in:))
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
#endif
