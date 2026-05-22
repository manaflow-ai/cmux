import Foundation
import OwlMojoBindingsGenerated

public protocol OwlBrowserRuntime: OwlFreshMojoPipeBindings {
    var runtimeDescription: String { get }
    var runtimeArchitecture: OwlBrowserRuntimeArchitecture { get }

    func initialize() throws
    func createSession(
        chromiumHost: String,
        initialURL: String,
        userDataDirectory: String,
        events: OwlBrowserSessionEvents
    ) throws -> OwlFreshMojoSessionHandle
    func destroy(_ session: OwlFreshMojoSessionHandle)
    func pollEvents(milliseconds: UInt32)
    func executeJavaScript(_ session: OwlFreshMojoSessionHandle, script: String) throws -> String
}

public struct OwlBrowserRuntimeArchitecture: Equatable, Encodable, Sendable {
    public let browserCommandTransport: String
    public let browserCallbackTransport: String
    public let chromiumRuntimeLinkMode: String
    public let swiftOwnsMojoPipeHandles: Bool
    public let usesUnixSocketBrowserTransport: Bool
    public let legacyCAbiBrowserCommandDispatch: Bool

    public init(
        browserCommandTransport: String,
        browserCallbackTransport: String,
        chromiumRuntimeLinkMode: String,
        swiftOwnsMojoPipeHandles: Bool,
        usesUnixSocketBrowserTransport: Bool,
        legacyCAbiBrowserCommandDispatch: Bool
    ) {
        self.browserCommandTransport = browserCommandTransport
        self.browserCallbackTransport = browserCallbackTransport
        self.chromiumRuntimeLinkMode = chromiumRuntimeLinkMode
        self.swiftOwnsMojoPipeHandles = swiftOwnsMojoPipeHandles
        self.usesUnixSocketBrowserTransport = usesUnixSocketBrowserTransport
        self.legacyCAbiBrowserCommandDispatch = legacyCAbiBrowserCommandDispatch
    }

    public static let generatedSwiftMojoTestDouble = OwlBrowserRuntimeArchitecture(
        browserCommandTransport: "generated-swift-mojo-test-double",
        browserCallbackTransport: "generated-swift-mojo-test-double",
        chromiumRuntimeLinkMode: "none",
        swiftOwnsMojoPipeHandles: true,
        usesUnixSocketBrowserTransport: false,
        legacyCAbiBrowserCommandDispatch: false
    )
}

public extension OwlBrowserRuntime {
    var runtimeDescription: String {
        "\(String(describing: type(of: self))) generated Mojo pipe bindings"
    }

    var runtimeArchitecture: OwlBrowserRuntimeArchitecture {
        .generatedSwiftMojoTestDouble
    }

    func captureSurfacePNG(_ session: OwlFreshMojoSessionHandle, to url: URL) throws -> OwlBrowserSurfaceCapture {
        let result = try surfaceTreeHostCaptureSurface(session)
        return try writeCaptureResult(result, to: url)
    }

    func captureSurfacePNG(
        _ session: OwlFreshMojoSessionHandle,
        label: String,
        to url: URL
    ) throws -> OwlBrowserSurfaceCapture {
        let result = try surfaceTreeHostCaptureSurface(session, label: label)
        return try writeCaptureResult(result, to: url)
    }

    private func writeCaptureResult(_ result: OwlFreshCaptureResult, to url: URL) throws -> OwlBrowserSurfaceCapture {
        guard result.error.isEmpty else {
            throw OwlBrowserError.capture("CaptureSurface failed: \(result.error)")
        }
        let data = Data(result.png)
        guard !data.isEmpty else {
            throw OwlBrowserError.capture("CaptureSurface returned empty PNG data")
        }
        try data.write(to: url)
        return OwlBrowserSurfaceCapture(path: url.path, mode: result.captureMode, width: result.width, height: result.height)
    }
}
