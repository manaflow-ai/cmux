import Foundation
import OwlMojoBindingsGenerated
import OwlMojoBindingsRuntime

public final class OwlBrowserSessionController {
    private let pipe: OwlFreshMojoPipeBindings
    private let session: OwlFreshMojoSessionHandle
    private let handleAllocator: OwlFreshMojoPipeHandleAllocating
    private let sink: GeneratedOwlFreshMojoPipeBoundSinks
    private let recorder: OwlFreshMojoTransportRecorder
    private let sessionTransport: GeneratedOwlFreshSessionMojoTransport
    private let webViewTransport: GeneratedOwlFreshWebViewMojoTransport
    private let inputTransport: GeneratedOwlFreshInputMojoTransport
    private let surfaceTreeTransport: GeneratedOwlFreshSurfaceTreeHostMojoTransport

    public init(
        pipe: OwlFreshMojoPipeBindings,
        session: OwlFreshMojoSessionHandle,
        handleAllocator: OwlFreshMojoPipeHandleAllocating? = nil
    ) throws {
        self.pipe = pipe
        self.session = session
        self.handleAllocator = handleAllocator ?? (pipe as? OwlFreshMojoPipeHandleAllocating) ?? OwlFreshMojoPipeHandleAllocator()
        self.sink = GeneratedOwlFreshMojoPipeBoundSinks(session: session, pipe: pipe)
        self.recorder = OwlFreshMojoTransportRecorder()
        self.sessionTransport = GeneratedOwlFreshSessionMojoTransport(sink: sink, recorder: recorder)
        self.webViewTransport = GeneratedOwlFreshWebViewMojoTransport(sink: sink, recorder: recorder)
        self.inputTransport = GeneratedOwlFreshInputMojoTransport(sink: sink, recorder: recorder)
        self.surfaceTreeTransport = GeneratedOwlFreshSurfaceTreeHostMojoTransport(sink: sink, recorder: recorder)
        try bindSessionInterfaces()
    }

    public var recordedCalls: [OwlFreshMojoTransportCall] {
        recorder.recordedCalls
    }

    public func navigate(_ url: String) throws {
        webViewTransport.navigate(url)
        try sink.throwIfFailed()
    }

    public func resize(_ request: OwlFreshWebViewResizeRequest) throws {
        webViewTransport.resize(request)
        try sink.throwIfFailed()
    }

    public func setFocus(_ focused: Bool) throws {
        webViewTransport.setFocus(focused)
        try sink.throwIfFailed()
    }

    public func goBack() throws {
        webViewTransport.goBack()
        try sink.throwIfFailed()
    }

    public func goForward() throws {
        webViewTransport.goForward()
        try sink.throwIfFailed()
    }

    public func reload() throws {
        webViewTransport.reload()
        try sink.throwIfFailed()
    }

    public func stopLoading() throws {
        webViewTransport.stopLoading()
        try sink.throwIfFailed()
    }

    public func sendMouse(_ event: OwlFreshMouseEvent) throws {
        inputTransport.sendMouse(event)
        try sink.throwIfFailed()
    }

    public func sendWheel(_ event: OwlFreshWheelEvent) throws {
        inputTransport.sendWheel(event)
        try sink.throwIfFailed()
    }

    public func sendKey(_ event: OwlFreshKeyEvent) throws {
        inputTransport.sendKey(event)
        try sink.throwIfFailed()
    }

    public func sendComposition(_ event: OwlFreshCompositionEvent) throws {
        inputTransport.sendComposition(event)
        try sink.throwIfFailed()
    }

    public func executeEditCommand(_ command: String) throws {
        inputTransport.executeEditCommand(command)
        try sink.throwIfFailed()
    }

    public func flush() async throws -> Bool {
        let result = try await sessionTransport.flush()
        try sink.throwIfFailed()
        return result
    }

    public func captureSurface() async throws -> OwlFreshCaptureResult {
        let result = try await surfaceTreeTransport.captureSurface()
        try sink.throwIfFailed()
        return result
    }

    public func captureSurface(label: String) async throws -> OwlFreshCaptureResult {
        let result = try await surfaceTreeTransport.captureSurface(label: label)
        try sink.throwIfFailed()
        return result
    }

    public func getSurfaceTree() throws -> OwlFreshSurfaceTree {
        try pipe.surfaceTreeHostGetSurfaceTree(session)
    }

    public func profilePath() throws -> String {
        try pipe.profileGetPath(session)
    }

    public func acceptActivePopupMenuItem(_ index: UInt32) throws -> Bool {
        try pipe.nativeSurfaceHostAcceptActivePopupMenuItem(session, index: index)
    }

    public func cancelActivePopup() throws -> Bool {
        try pipe.nativeSurfaceHostCancelActivePopup(session)
    }

    public func selectActiveFilePickerFiles(_ paths: [String]) throws -> Bool {
        try pipe.nativeSurfaceHostSelectActiveFilePickerFiles(session, paths: paths)
    }

    public func cancelActiveFilePicker() throws -> Bool {
        try pipe.nativeSurfaceHostCancelActiveFilePicker(session)
    }

    public func acceptActivePermissionPrompt() throws -> Bool {
        try pipe.nativeSurfaceHostAcceptActivePermissionPrompt(session)
    }

    public func cancelActivePermissionPrompt() throws -> Bool {
        try pipe.nativeSurfaceHostCancelActivePermissionPrompt(session)
    }

    public func submitActiveAuthPrompt(username: String, password: String) throws -> Bool {
        try pipe.nativeSurfaceHostSubmitActiveAuthPrompt(session, username: username, password: password)
    }

    public func cancelActiveAuthPrompt() throws -> Bool {
        try pipe.nativeSurfaceHostCancelActiveAuthPrompt(session)
    }

    public func openDevTools(_ mode: OwlFreshDevToolsMode) throws -> Bool {
        recorder.record(
            interface: "OwlFreshDevToolsHost",
            method: "openDevTools",
            payloadType: "OwlFreshDevToolsMode",
            payloadSummary: String(describing: mode)
        )
        return try pipe.devToolsHostOpenDevTools(session, mode: mode)
    }

    public func closeDevTools() throws -> Bool {
        recorder.record(
            interface: "OwlFreshDevToolsHost",
            method: "closeDevTools",
            payloadType: "Void",
            payloadSummary: ""
        )
        return try pipe.devToolsHostCloseDevTools(session)
    }

    public func evaluateDevToolsJavaScript(_ script: String) throws -> String {
        recorder.record(
            interface: "OwlFreshDevToolsHost",
            method: "evaluateDevToolsJavaScript",
            payloadType: "String",
            payloadSummary: String(describing: script)
        )
        return try pipe.devToolsHostEvaluateDevToolsJavaScript(session, script: script)
    }

    private func bindSessionInterfaces() throws {
        let profile: OwlFreshProfileReceiver = try handleAllocator.makeReceiver(OwlFreshProfileMojoInterfaceMarker.self)
        let webView: OwlFreshWebViewReceiver = try handleAllocator.makeReceiver(OwlFreshWebViewMojoInterfaceMarker.self)
        let input: OwlFreshInputReceiver = try handleAllocator.makeReceiver(OwlFreshInputMojoInterfaceMarker.self)
        let surfaceTree: OwlFreshSurfaceTreeHostReceiver = try handleAllocator.makeReceiver(
            OwlFreshSurfaceTreeHostMojoInterfaceMarker.self
        )
        let nativeSurfaceHost: OwlFreshNativeSurfaceHostReceiver = try handleAllocator.makeReceiver(
            OwlFreshNativeSurfaceHostMojoInterfaceMarker.self
        )
        let devToolsHost: OwlFreshDevToolsHostReceiver = try handleAllocator.makeReceiver(
            OwlFreshDevToolsHostMojoInterfaceMarker.self
        )
        let client: OwlFreshClientRemote = try handleAllocator.makeRemote(OwlFreshClientMojoInterfaceMarker.self)

        sessionTransport.bindProfile(profile)
        try sink.throwIfFailed()
        sessionTransport.bindWebView(webView)
        try sink.throwIfFailed()
        sessionTransport.bindInput(input)
        try sink.throwIfFailed()
        sessionTransport.bindSurfaceTree(surfaceTree)
        try sink.throwIfFailed()
        sessionTransport.bindNativeSurfaceHost(nativeSurfaceHost)
        try sink.throwIfFailed()
        sessionTransport.bindDevToolsHost(devToolsHost)
        try sink.throwIfFailed()
        sessionTransport.setClient(client)
        try sink.throwIfFailed()
    }
}
