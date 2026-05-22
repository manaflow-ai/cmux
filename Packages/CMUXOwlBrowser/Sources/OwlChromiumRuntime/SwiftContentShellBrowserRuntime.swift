import Foundation
import OwlBrowserCore
import OwlMojoBindingsGenerated
import OwlMojoBindingsRuntime
import OwlMojoSystem

public final class SwiftContentShellBrowserRuntime: OwlBrowserRuntime, OwlFreshMojoPipeHandleAllocating {
    private let runtimeLibrary: OwlChromiumRuntimeLibrary
    private let handleAllocator: OwlFreshMojoPipeHandleAllocating
    private let endpointPairResolver: OwlFreshMojoEndpointPairResolving?
    private let mojoSystem: DynamicMojoSystem
    private let swiftBootstrap: SwiftContentShellMojoBootstrap
    private let directSessionsLock = NSLock()
    private var directSessions: [UInt: DirectSessionTransports] = [:]

    public var runtimeDescription: String {
        "SwiftContentShellBrowserRuntime with Swift-owned Content Shell launch and generated Mojo pipe handles"
    }

    public var runtimeArchitecture: OwlBrowserRuntimeArchitecture {
        OwlBrowserRuntimeArchitecture(
            browserCommandTransport: "generated-swift-mojo-pipe-bindings",
            browserCallbackTransport: "generated-swift-mojo-client-receiver",
            chromiumRuntimeLinkMode: runtimeLibrary.linkMode,
            swiftOwnsMojoPipeHandles: true,
            usesUnixSocketBrowserTransport: false,
            legacyCAbiBrowserCommandDispatch: false
        )
    }

    public convenience init(path: String) throws {
        try self.init(runtimeLibrary: OwlChromiumRuntimeLibrary(path: path))
    }

    public init(runtimeLibrary: OwlChromiumRuntimeLibrary) {
        self.runtimeLibrary = runtimeLibrary
        let mojoSystem = runtimeLibrary.mojoSystem
        self.mojoSystem = mojoSystem
        self.swiftBootstrap = SwiftContentShellMojoBootstrap(mojoSystem: mojoSystem)
        let allocator = OwlFreshMojoSystemPipeHandleAllocator(system: mojoSystem)
        self.handleAllocator = allocator
        self.endpointPairResolver = allocator
    }

    public func initialize() throws {
        try runtimeLibrary.initialize()
    }

    public func makeRemote<Interface>(_ interface: Interface.Type = Interface.self) throws -> MojoPendingRemote<Interface> {
        try handleAllocator.makeRemote(interface)
    }

    public func makeReceiver<Interface>(_ interface: Interface.Type = Interface.self) throws -> MojoPendingReceiver<Interface> {
        try handleAllocator.makeReceiver(interface)
    }

    public func createSession(
        chromiumHost: String,
        initialURL: String,
        userDataDirectory: String,
        events: OwlBrowserSessionEvents
    ) throws -> OwlFreshMojoSessionHandle {
        let session = try swiftBootstrap.createSession(
            chromiumHost: chromiumHost,
            initialURL: initialURL,
            userDataDirectory: userDataDirectory
        )
        let retained = Unmanaged.passRetained(session).toOpaque()
        let handle = OwlFreshMojoSessionHandle(rawValue: OpaquePointer(retained))
        storeDirectSession(handle, events: events)
        let directSession = directSession(for: handle)
        directSession.contentShellSession = session
        directSession.profileDirectory = userDataDirectory
        directSession.hostPID = Int32(session.process.processIdentifier)
        events.recordHostPID(directSession.hostPID)
        try bindShellController(
            remoteHandle: session.shellControllerRemoteHandle,
            directSession: directSession
        )
        return handle
    }

    public func destroy(_ session: OwlFreshMojoSessionHandle) {
        guard let rawValue = session.rawValue else {
            return
        }
        let directSession = removeDirectSession(session)
        try? directSession?.shellController?.shutdown()
        let unmanaged = Unmanaged<SwiftContentShellSession>.fromOpaque(UnsafeMutableRawPointer(rawValue))
        unmanaged.takeUnretainedValue().destroy()
        unmanaged.release()
    }

    public func pollEvents(milliseconds: UInt32) {
        drainDirectClientEvents()
    }

    public func executeJavaScript(_ session: OwlFreshMojoSessionHandle, script: String) throws -> String {
        try requireDirectTransport(directSessionIfPresent(for: session)?.shellController, "ShellController")
            .executeJavaScript(script)
    }

    public func sessionSetClient(_ session: OwlFreshMojoSessionHandle, client: OwlFreshClientRemote) throws {
        let pair = try requireEndpointPair(for: client.handle, interfaceName: "OwlFreshClient")
        let directSession = directSession(for: session)
        try requireDirectTransport(directSession.session, "OwlFreshSession")
            .setClient(remoteHandle: pair.remoteHandle)
        directSession.client = OwlFreshClientDirectMojoReceiver(
            reader: mojoSystem,
            closer: mojoSystem,
            receiverHandle: pair.receiverHandle,
            sink: directSession.events
        )
    }

    public func sessionBindProfile(_ session: OwlFreshMojoSessionHandle, profile: OwlFreshProfileReceiver) throws {
        let pair = try requireEndpointPair(for: profile.handle, interfaceName: "OwlFreshProfile")
        let directSession = directSession(for: session)
        try requireDirectTransport(directSession.session, "OwlFreshSession")
            .bindProfile(receiverHandle: pair.receiverHandle)
        directSession.profile = OwlFreshProfileDirectMojoTransport(
            writer: mojoSystem,
            reader: mojoSystem,
            closer: mojoSystem,
            remoteHandle: pair.remoteHandle
        )
    }

    public func sessionBindWebView(_ session: OwlFreshMojoSessionHandle, webView: OwlFreshWebViewReceiver) throws {
        let pair = try requireEndpointPair(for: webView.handle, interfaceName: "OwlFreshWebView")
        let directSession = directSession(for: session)
        try requireDirectTransport(directSession.session, "OwlFreshSession")
            .bindWebView(receiverHandle: pair.receiverHandle)
        directSession.webView = OwlFreshWebViewDirectMojoTransport(
            writer: mojoSystem,
            closer: mojoSystem,
            remoteHandle: pair.remoteHandle
        )
    }

    public func sessionBindInput(_ session: OwlFreshMojoSessionHandle, input: OwlFreshInputReceiver) throws {
        let pair = try requireEndpointPair(for: input.handle, interfaceName: "OwlFreshInput")
        let directSession = directSession(for: session)
        try requireDirectTransport(directSession.session, "OwlFreshSession")
            .bindInput(receiverHandle: pair.receiverHandle)
        directSession.input = OwlFreshInputDirectMojoTransport(
            writer: mojoSystem,
            closer: mojoSystem,
            remoteHandle: pair.remoteHandle
        )
    }

    public func sessionBindSurfaceTree(
        _ session: OwlFreshMojoSessionHandle,
        surfaceTree: OwlFreshSurfaceTreeHostReceiver
    ) throws {
        let pair = try requireEndpointPair(for: surfaceTree.handle, interfaceName: "OwlFreshSurfaceTreeHost")
        let directSession = directSession(for: session)
        try requireDirectTransport(directSession.session, "OwlFreshSession")
            .bindSurfaceTree(receiverHandle: pair.receiverHandle)
        directSession.surfaceTreeHost = OwlFreshSurfaceTreeHostDirectMojoTransport(
            writer: mojoSystem,
            reader: mojoSystem,
            closer: mojoSystem,
            remoteHandle: pair.remoteHandle
        )
    }

    public func sessionBindNativeSurfaceHost(
        _ session: OwlFreshMojoSessionHandle,
        nativeSurfaceHost: OwlFreshNativeSurfaceHostReceiver
    ) throws {
        let pair = try requireEndpointPair(for: nativeSurfaceHost.handle, interfaceName: "OwlFreshNativeSurfaceHost")
        let directSession = directSession(for: session)
        try requireDirectTransport(directSession.session, "OwlFreshSession")
            .bindNativeSurfaceHost(receiverHandle: pair.receiverHandle)
        directSession.nativeSurfaceHost = OwlFreshNativeSurfaceHostDirectMojoTransport(
            writer: mojoSystem,
            reader: mojoSystem,
            closer: mojoSystem,
            remoteHandle: pair.remoteHandle
        )
    }

    public func sessionBindDevToolsHost(
        _ session: OwlFreshMojoSessionHandle,
        devtoolsHost: OwlFreshDevToolsHostReceiver
    ) throws {
        let pair = try requireEndpointPair(for: devtoolsHost.handle, interfaceName: "OwlFreshDevToolsHost")
        let directSession = directSession(for: session)
        try requireDirectTransport(directSession.session, "OwlFreshSession")
            .bindDevToolsHost(receiverHandle: pair.receiverHandle)
        directSession.devToolsHost = OwlFreshDevToolsHostDirectMojoTransport(
            writer: mojoSystem,
            reader: mojoSystem,
            closer: mojoSystem,
            remoteHandle: pair.remoteHandle
        )
    }

    public func sessionFlush(_ session: OwlFreshMojoSessionHandle) throws -> Bool {
        drainDirectClientEvents()
        let flushed = try requireDirectTransport(directSessionIfPresent(for: session)?.session, "OwlFreshSession")
            .flush()
        drainDirectClientEvents()
        return flushed
    }

    public func profileGetPath(_ session: OwlFreshMojoSessionHandle) throws -> String {
        let directSession = try requireDirectSession(for: session)
        if let profile = directSession.profile {
            return try profile.getPath()
        }
        return directSession.profileDirectory
    }

    public func webViewNavigate(_ session: OwlFreshMojoSessionHandle, url: String) throws {
        try requireDirectTransport(directSessionIfPresent(for: session)?.webView, "OwlFreshWebView")
            .navigate(to: url)
    }

    public func webViewResize(_ session: OwlFreshMojoSessionHandle, request: OwlFreshWebViewResizeRequest) throws {
        let directSession = try requireDirectSession(for: session)
        directSession.lastViewport = request
        try requireDirectTransport(directSession.webView, "OwlFreshWebView").resize(request)
    }

    public func webViewSetFocus(_ session: OwlFreshMojoSessionHandle, focused: Bool) throws {
        try requireDirectTransport(directSessionIfPresent(for: session)?.webView, "OwlFreshWebView")
            .setFocus(focused)
    }

    public func webViewGoBack(_ session: OwlFreshMojoSessionHandle) throws {
        try requireDirectTransport(directSessionIfPresent(for: session)?.webView, "OwlFreshWebView")
            .goBack()
    }

    public func webViewGoForward(_ session: OwlFreshMojoSessionHandle) throws {
        try requireDirectTransport(directSessionIfPresent(for: session)?.webView, "OwlFreshWebView")
            .goForward()
    }

    public func webViewReload(_ session: OwlFreshMojoSessionHandle) throws {
        try requireDirectTransport(directSessionIfPresent(for: session)?.webView, "OwlFreshWebView")
            .reload()
    }

    public func webViewStopLoading(_ session: OwlFreshMojoSessionHandle) throws {
        try requireDirectTransport(directSessionIfPresent(for: session)?.webView, "OwlFreshWebView")
            .stopLoading()
    }

    public func inputSendMouse(_ session: OwlFreshMojoSessionHandle, event: OwlFreshMouseEvent) throws {
        try requireDirectTransport(directSessionIfPresent(for: session)?.input, "OwlFreshInput")
            .sendMouse(event)
    }

    public func inputSendWheel(_ session: OwlFreshMojoSessionHandle, event: OwlFreshWheelEvent) throws {
        try requireDirectTransport(directSessionIfPresent(for: session)?.input, "OwlFreshInput")
            .sendWheel(event)
    }

    public func inputSendKey(_ session: OwlFreshMojoSessionHandle, event: OwlFreshKeyEvent) throws {
        try requireDirectTransport(directSessionIfPresent(for: session)?.input, "OwlFreshInput")
            .sendKey(event)
    }

    public func inputSendComposition(_ session: OwlFreshMojoSessionHandle, event: OwlFreshCompositionEvent) throws {
        try requireDirectTransport(directSessionIfPresent(for: session)?.input, "OwlFreshInput")
            .sendComposition(event)
    }

    public func inputExecuteEditCommand(_ session: OwlFreshMojoSessionHandle, command: String) throws {
        try requireDirectTransport(directSessionIfPresent(for: session)?.input, "OwlFreshInput")
            .executeEditCommand(command)
    }

    public func surfaceTreeHostCaptureSurface(_ session: OwlFreshMojoSessionHandle) throws -> OwlFreshCaptureResult {
        try requireDirectTransport(directSessionIfPresent(for: session)?.surfaceTreeHost, "OwlFreshSurfaceTreeHost")
            .captureSurface()
    }

    public func surfaceTreeHostCaptureSurface(
        _ session: OwlFreshMojoSessionHandle,
        label: String
    ) throws -> OwlFreshCaptureResult {
        try requireDirectTransport(directSessionIfPresent(for: session)?.surfaceTreeHost, "OwlFreshSurfaceTreeHost")
            .captureSurface(label: label)
    }

    public func surfaceTreeHostGetSurfaceTree(_ session: OwlFreshMojoSessionHandle) throws -> OwlFreshSurfaceTree {
        try requireDirectTransport(directSessionIfPresent(for: session)?.surfaceTreeHost, "OwlFreshSurfaceTreeHost")
            .getSurfaceTree()
    }

    public func nativeSurfaceHostAcceptActivePopupMenuItem(
        _ session: OwlFreshMojoSessionHandle,
        index: UInt32
    ) throws -> Bool {
        try requireDirectTransport(directSessionIfPresent(for: session)?.nativeSurfaceHost, "OwlFreshNativeSurfaceHost")
            .acceptActivePopupMenuItem(index: index)
    }

    public func nativeSurfaceHostCancelActivePopup(_ session: OwlFreshMojoSessionHandle) throws -> Bool {
        try requireDirectTransport(directSessionIfPresent(for: session)?.nativeSurfaceHost, "OwlFreshNativeSurfaceHost")
            .cancelActivePopup()
    }

    public func nativeSurfaceHostSelectActiveFilePickerFiles(
        _ session: OwlFreshMojoSessionHandle,
        paths: [String]
    ) throws -> Bool {
        try requireDirectTransport(directSessionIfPresent(for: session)?.nativeSurfaceHost, "OwlFreshNativeSurfaceHost")
            .selectActiveFilePickerFiles(paths: paths)
    }

    public func nativeSurfaceHostCancelActiveFilePicker(_ session: OwlFreshMojoSessionHandle) throws -> Bool {
        try requireDirectTransport(directSessionIfPresent(for: session)?.nativeSurfaceHost, "OwlFreshNativeSurfaceHost")
            .cancelActiveFilePicker()
    }

    public func nativeSurfaceHostAcceptActivePermissionPrompt(_ session: OwlFreshMojoSessionHandle) throws -> Bool {
        try requireDirectTransport(directSessionIfPresent(for: session)?.nativeSurfaceHost, "OwlFreshNativeSurfaceHost")
            .acceptActivePermissionPrompt()
    }

    public func nativeSurfaceHostCancelActivePermissionPrompt(_ session: OwlFreshMojoSessionHandle) throws -> Bool {
        try requireDirectTransport(directSessionIfPresent(for: session)?.nativeSurfaceHost, "OwlFreshNativeSurfaceHost")
            .cancelActivePermissionPrompt()
    }

    public func nativeSurfaceHostSubmitActiveAuthPrompt(
        _ session: OwlFreshMojoSessionHandle,
        username: String,
        password: String
    ) throws -> Bool {
        try requireDirectTransport(directSessionIfPresent(for: session)?.nativeSurfaceHost, "OwlFreshNativeSurfaceHost")
            .submitActiveAuthPrompt(username: username, password: password)
    }

    public func nativeSurfaceHostCancelActiveAuthPrompt(_ session: OwlFreshMojoSessionHandle) throws -> Bool {
        try requireDirectTransport(directSessionIfPresent(for: session)?.nativeSurfaceHost, "OwlFreshNativeSurfaceHost")
            .cancelActiveAuthPrompt()
    }

    public func devToolsHostOpenDevTools(
        _ session: OwlFreshMojoSessionHandle,
        mode: OwlFreshDevToolsMode
    ) throws -> Bool {
        try requireDirectTransport(directSessionIfPresent(for: session)?.devToolsHost, "OwlFreshDevToolsHost")
            .openDevTools(mode)
    }

    public func devToolsHostCloseDevTools(_ session: OwlFreshMojoSessionHandle) throws -> Bool {
        try requireDirectTransport(directSessionIfPresent(for: session)?.devToolsHost, "OwlFreshDevToolsHost")
            .closeDevTools()
    }

    public func devToolsHostEvaluateDevToolsJavaScript(
        _ session: OwlFreshMojoSessionHandle,
        script: String
    ) throws -> String {
        try requireDirectTransport(directSessionIfPresent(for: session)?.devToolsHost, "OwlFreshDevToolsHost")
            .evaluateDevToolsJavaScript(script)
    }

    private func storeDirectSession(_ session: OwlFreshMojoSessionHandle, events: OwlBrowserSessionEvents) {
        guard let key = sessionKey(session) else {
            return
        }
        directSessionsLock.withLock {
            directSessions[key] = DirectSessionTransports(events: events)
        }
    }

    private func removeDirectSession(_ session: OwlFreshMojoSessionHandle) -> DirectSessionTransports? {
        guard let key = sessionKey(session) else {
            return nil
        }
        return directSessionsLock.withLock {
            directSessions.removeValue(forKey: key)
        }
    }

    private func directSession(for session: OwlFreshMojoSessionHandle) -> DirectSessionTransports {
        let key = sessionKey(session) ?? 0
        return directSessionsLock.withLock {
            if let existing = directSessions[key] {
                return existing
            }
            let created = DirectSessionTransports(events: OwlBrowserSessionEvents())
            directSessions[key] = created
            return created
        }
    }

    private func directSessionIfPresent(for session: OwlFreshMojoSessionHandle) -> DirectSessionTransports? {
        guard let key = sessionKey(session) else {
            return nil
        }
        return directSessionsLock.withLock {
            directSessions[key]
        }
    }

    private func drainDirectClientEvents() {
        let transports = directSessionsLock.withLock {
            Array(directSessions.values)
        }
        for transport in transports {
            if let contentShellSession = transport.contentShellSession,
               contentShellSession.hasExited() {
                transport.events.recordDisconnected()
                transport.events.recordLog("Content Shell process exited: \(contentShellSession.terminationStatusDescription)")
                continue
            }
            do {
                try transport.client?.drainAvailableMessages()
            } catch let error as MojoSystemError where error.isFailedPrecondition {
                transport.events.recordDisconnected()
                transport.events.recordLog("direct OwlFreshClient Mojo peer disconnected: \(error)")
            } catch {
                transport.events.recordLog("direct OwlFreshClient Mojo receive failed: \(error)")
            }
        }
    }

    private func sessionKey(_ session: OwlFreshMojoSessionHandle) -> UInt? {
        guard let rawValue = session.rawValue else {
            return nil
        }
        return UInt(bitPattern: UnsafeMutableRawPointer(rawValue))
    }

    private func requireEndpointPair(
        for handle: UInt64,
        interfaceName: String
    ) throws -> OwlFreshMojoEndpointPair {
        guard let pair = consumeEndpointPair(for: handle) else {
            throw OwlBrowserError.bridge("\(interfaceName) must be created by the generated Swift Mojo pipe allocator")
        }
        return pair
    }

    private func requireDirectTransport<Transport>(
        _ transport: Transport?,
        _ interfaceName: String
    ) throws -> Transport {
        guard let transport else {
            throw OwlBrowserError.bridge("\(interfaceName) direct Mojo transport is not bound")
        }
        return transport
    }

    private func requireDirectSession(for session: OwlFreshMojoSessionHandle) throws -> DirectSessionTransports {
        guard let directSession = directSessionIfPresent(for: session) else {
            throw OwlBrowserError.bridge("session transport is not bound")
        }
        return directSession
    }

    private func consumeEndpointPair(for handle: UInt64) -> OwlFreshMojoEndpointPair? {
        endpointPairResolver?.consumeEndpointPair(returnedHandle: handle)
    }

    private func bindShellController(remoteHandle: UInt64, directSession: DirectSessionTransports) throws {
        let shellController = OwlFreshShellControllerDirectMojoTransport(
            writer: mojoSystem,
            reader: mojoSystem,
            closer: mojoSystem,
            remoteHandle: remoteHandle
        )
        let sessionPipe = try mojoSystem.createMessagePipe()
        try shellController.bindOwlFreshSession(receiverHandle: UInt64(sessionPipe.endpoint1.rawValue))
        directSession.shellController = shellController
        directSession.session = OwlFreshSessionDirectMojoTransport(
            writer: mojoSystem,
            reader: mojoSystem,
            closer: mojoSystem,
            remoteHandle: UInt64(sessionPipe.endpoint0.rawValue)
        )
    }
}

private final class DirectSessionTransports {
    let events: OwlBrowserSessionEvents
    var hostPID: Int32 = -1
    var profileDirectory = ""
    var lastViewport = OwlFreshWebViewResizeRequest(width: 800, height: 600, scale: 1)
    var contentShellSession: SwiftContentShellSession?
    var shellController: OwlFreshShellControllerDirectMojoTransport?
    var session: OwlFreshSessionDirectMojoTransport?
    var client: OwlFreshClientDirectMojoReceiver?
    var profile: OwlFreshProfileDirectMojoTransport?
    var webView: OwlFreshWebViewDirectMojoTransport?
    var input: OwlFreshInputDirectMojoTransport?
    var surfaceTreeHost: OwlFreshSurfaceTreeHostDirectMojoTransport?
    var nativeSurfaceHost: OwlFreshNativeSurfaceHostDirectMojoTransport?
    var devToolsHost: OwlFreshDevToolsHostDirectMojoTransport?

    init(events: OwlBrowserSessionEvents) {
        self.events = events
    }
}
