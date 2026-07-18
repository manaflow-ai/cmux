public import Foundation

/// IOSurface pixel layout requested from the workspace renderer.
public enum BackendRendererPixelFormat: String, Codable, Sendable {
    case bgra8Unorm = "bgra8-unorm"
    case rgba16Float = "rgba16-float"
}

/// Color-space semantics requested from the workspace renderer.
public enum BackendRendererColorSpace: String, Codable, Sendable {
    case sRGB = "srgb"
    case displayP3 = "display-p3"
    case extendedLinearSRGB = "extended-linear-srgb"
}

/// Current lifecycle state of a disposable workspace renderer.
public enum BackendRendererWorkerState: String, Codable, Sendable {
    case starting
    case ready
    case backoff
}

/// Padding reserved around the terminal grid in renderer pixels.
public struct BackendRendererPadding: Decodable, Equatable, Sendable {
    public let left: UInt32
    public let top: UInt32
    public let right: UInt32
    public let bottom: UInt32

    public init(left: UInt32 = 0, top: UInt32 = 0, right: UInt32 = 0, bottom: UInt32 = 0) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }
}

/// Exact font-grid geometry measured inside the Ghostty renderer process.
public struct BackendRendererMetrics: Decodable, Equatable, Sendable {
    public let columns: UInt16
    public let rows: UInt16
    public let cellWidth: UInt32
    public let cellHeight: UInt32
    public let padding: BackendRendererPadding

    private enum CodingKeys: String, CodingKey {
        case columns
        case rows
        case cellWidth = "cell_width"
        case cellHeight = "cell_height"
        case padding
    }
}

/// Complete renderer attachment configuration for one canonical presentation.
public struct BackendRendererPresentationConfiguration: Equatable, Sendable {
    public let width: UInt32
    public let height: UInt32
    public let backingScaleFactor: Double
    public let columns: UInt16
    public let rows: UInt16
    public let pixelFormat: BackendRendererPixelFormat
    public let colorSpace: BackendRendererColorSpace
    public let frameEndpointService: String
    public let frameEndpointCapability: Data
    public let resolvedConfigRevision: UInt64
    public let resolvedConfig: Data
    public let focused: Bool
    public let cursorBlinkVisible: Bool
    public let preedit: String?
    public let preeditSelectionStartUTF16: UInt32
    public let preeditSelectionLengthUTF16: UInt32
    public let preeditCaretUTF16: UInt32

    public init(
        width: UInt32,
        height: UInt32,
        backingScaleFactor: Double,
        columns: UInt16,
        rows: UInt16,
        pixelFormat: BackendRendererPixelFormat,
        colorSpace: BackendRendererColorSpace,
        frameEndpointService: String,
        frameEndpointCapability: Data,
        resolvedConfigRevision: UInt64 = 0,
        resolvedConfig: Data = Data(),
        focused: Bool = true,
        cursorBlinkVisible: Bool = true,
        preedit: String? = nil,
        preeditSelectionStartUTF16: UInt32 = 0,
        preeditSelectionLengthUTF16: UInt32 = 0,
        preeditCaretUTF16: UInt32 = 0
    ) {
        self.width = width
        self.height = height
        self.backingScaleFactor = backingScaleFactor
        self.columns = columns
        self.rows = rows
        self.pixelFormat = pixelFormat
        self.colorSpace = colorSpace
        self.frameEndpointService = frameEndpointService
        self.frameEndpointCapability = frameEndpointCapability
        self.resolvedConfigRevision = resolvedConfigRevision
        self.resolvedConfig = resolvedConfig
        self.focused = focused
        self.cursorBlinkVisible = cursorBlinkVisible
        self.preedit = preedit
        self.preeditSelectionStartUTF16 = preeditSelectionStartUTF16
        self.preeditSelectionLengthUTF16 = preeditSelectionLengthUTF16
        self.preeditCaretUTF16 = preeditCaretUTF16
    }

    internal var jsonParameters: [String: BackendJSONValue] {
        var parameters: [String: BackendJSONValue] = [
            "width": .unsignedInteger(UInt64(width)),
            "height": .unsignedInteger(UInt64(height)),
            "backing_scale_factor": .number(backingScaleFactor),
            "columns": .unsignedInteger(UInt64(columns)),
            "rows": .unsignedInteger(UInt64(rows)),
            "pixel_format": .string(pixelFormat.rawValue),
            "color_space": .string(colorSpace.rawValue),
            "frame_endpoint_service": .string(frameEndpointService),
            "frame_endpoint_capability": .string(frameEndpointCapability.base64EncodedString()),
            "resolved_config_revision": .unsignedInteger(resolvedConfigRevision),
            "resolved_config": .string(resolvedConfig.base64EncodedString()),
            "focused": .bool(focused),
            "cursor_blink_visible": .bool(cursorBlinkVisible),
        ]
        parameters["preedit"] = preedit.map(BackendJSONValue.string) ?? .null
        parameters["preedit_selection_start_utf16"] = .unsignedInteger(
            UInt64(preeditSelectionStartUTF16)
        )
        parameters["preedit_selection_length_utf16"] = .unsignedInteger(
            UInt64(preeditSelectionLengthUTF16)
        )
        parameters["preedit_caret_utf16"] = .unsignedInteger(UInt64(preeditCaretUTF16))
        return parameters
    }
}

/// Typed IME marked text sent to the daemon-owned semantic scene.
public struct BackendTerminalPreedit: Equatable, Sendable {
    public let text: String
    public let selectionStartUTF16: UInt32
    public let selectionLengthUTF16: UInt32
    public let caretUTF16: UInt32

    public init(
        text: String,
        selectionStartUTF16: UInt32,
        selectionLengthUTF16: UInt32,
        caretUTF16: UInt32
    ) {
        self.text = text
        self.selectionStartUTF16 = selectionStartUTF16
        self.selectionLengthUTF16 = selectionLengthUTF16
        self.caretUTF16 = caretUTF16
    }
}

/// Generation and process fences installed for one renderer presentation.
public struct BackendRendererPresentationReceipt: Decodable, Equatable, Sendable {
    public let daemonInstanceID: DaemonInstanceID
    public let workspaceID: WorkspaceID
    public let rendererEpoch: UInt64
    public let workerState: BackendRendererWorkerState
    public let workerProcessID: UInt32?
    public let workerEffectiveUserID: UInt32?
    public let sceneCapabilities: UInt64?
    public let terminalID: SurfaceID
    public let terminalEpoch: UInt64
    public let presentationID: PresentationID
    public let canonicalGeneration: UInt64
    public let rendererGeneration: UInt64
    public let minimumContentSequence: UInt64
    public let width: UInt32
    public let height: UInt32
    public let backingScaleFactor: Double
    public let columns: UInt16
    public let rows: UInt16
    /// Nil while the worker is starting. Exact metrics arrive in a fenced ready event.
    public let metrics: BackendRendererMetrics?
    public let pixelFormat: BackendRendererPixelFormat
    public let colorSpace: BackendRendererColorSpace

    private enum CodingKeys: String, CodingKey {
        case daemonInstanceID = "daemon_instance_id"
        case workspaceID = "workspace_uuid"
        case rendererEpoch = "renderer_epoch"
        case workerState = "worker_state"
        case workerProcessID = "worker_pid"
        case workerEffectiveUserID = "worker_effective_user_id"
        case sceneCapabilities = "scene_capabilities"
        case terminalID = "terminal_id"
        case terminalEpoch = "terminal_epoch"
        case presentationID = "presentation_id"
        case canonicalGeneration = "generation"
        case rendererGeneration = "renderer_generation"
        case minimumContentSequence = "minimum_content_sequence"
        case width
        case height
        case backingScaleFactor = "backing_scale_factor"
        case columns
        case rows
        case metrics
        case pixelFormat = "pixel_format"
        case colorSpace = "color_space"
    }
}

/// Exact release fence forwarded to the renderer that produced a frame.
public struct BackendRendererFrameRelease: Equatable, Sendable {
    public let daemonInstanceID: DaemonInstanceID
    public let rendererEpoch: UInt64
    public let terminalID: SurfaceID
    public let terminalEpoch: UInt64
    public let terminalSequence: UInt64
    public let presentationID: PresentationID
    public let presentationGeneration: UInt64
    public let frameSequence: UInt64
    public let surfaceID: UInt32

    public init(
        daemonInstanceID: DaemonInstanceID,
        rendererEpoch: UInt64,
        terminalID: SurfaceID,
        terminalEpoch: UInt64,
        terminalSequence: UInt64,
        presentationID: PresentationID,
        presentationGeneration: UInt64,
        frameSequence: UInt64,
        surfaceID: UInt32
    ) {
        self.daemonInstanceID = daemonInstanceID
        self.rendererEpoch = rendererEpoch
        self.terminalID = terminalID
        self.terminalEpoch = terminalEpoch
        self.terminalSequence = terminalSequence
        self.presentationID = presentationID
        self.presentationGeneration = presentationGeneration
        self.frameSequence = frameSequence
        self.surfaceID = surfaceID
    }

    internal var jsonParameters: [String: BackendJSONValue] {
        [
            "daemon_instance_id": .string(daemonInstanceID.description),
            "renderer_epoch": .unsignedInteger(rendererEpoch),
            "terminal_id": .string(terminalID.description),
            "terminal_epoch": .unsignedInteger(terminalEpoch),
            "terminal_sequence": .unsignedInteger(terminalSequence),
            "presentation_id": .string(presentationID.description),
            "presentation_generation": .unsignedInteger(presentationGeneration),
            "frame_sequence": .unsignedInteger(frameSequence),
            "surface_id": .unsignedInteger(UInt64(surfaceID)),
        ]
    }
}

/// Whether an exact release reached a live worker or a bounded retired route.
public struct BackendRendererFrameReleaseResponse: Decodable, Equatable, Sendable {
    public let forwarded: Bool
}
