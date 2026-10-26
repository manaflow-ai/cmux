public import CmuxNextTrace

/// The rings and processes one recording reaches. A part this build lacks is nil, and the reply says
/// `unsupported` for it.
public struct TraceControlParts: Sendable {
    /// The app's own recording ring.
    public var app: any TraceAppRecording
    /// The daemon's `trace-start`, `trace-stop` and `trace-status` (task 015), which reach its children.
    public var daemon: (any TraceDaemonLink)?
    /// Chromium tracing in the process that runs CEF (task 051).
    public var chromium: (any TraceChromiumLink)?
    /// The typing flows (task 019): one flow id per key press while on.
    public var keyFlows: (any TraceKeyFlows)?
    /// The recording indicator (task 133).
    public var indicator: (any TraceRecordingIndicator)?
    /// Whether secure keyboard entry is on (task 128's gate).
    public var secureInput: any TraceSecureInput

    public init(app: any TraceAppRecording, daemon: (any TraceDaemonLink)? = nil, chromium: (any TraceChromiumLink)? = nil,
                keyFlows: (any TraceKeyFlows)? = nil, indicator: (any TraceRecordingIndicator)? = nil, secureInput: any TraceSecureInput) {
        self.app = app
        self.daemon = daemon
        self.chromium = chromium
        self.keyFlows = keyFlows
        self.indicator = indicator
        self.secureInput = secureInput
    }
}

/// The app's recording ring.
public protocol TraceAppRecording: Sendable {
    /// Maps the recording ring ahead of a start (blocking file work, run off the caller's thread).
    ///
    /// - Returns: Whether the ring is ready.
    func prepare() async -> Bool
    /// Starts the recording (no disk I/O).
    func start(_ request: TraceRuntime.RecordingRequest) -> TraceRuntime.RecordingStatus
    /// Stops it; the result names the ring's file.
    func stop() -> TraceRuntime.RecordingStatus
    /// The ring's state now.
    var status: TraceRuntime.RecordingStatus { get }
}

/// The recording indicator (task 133).
    public var indicator: (any TraceRecordingIndicator)?
    /// Whether secure keyboard entry is on (task 128's gate).
    public var secureInput: any TraceSecureInput

    public init(app: any TraceAppRecording, daemon: (any TraceDaemonLink)? = nil, chromium: (any TraceChromiumLink)? = nil,
                keyFlows: (any TraceKeyFlows)? = nil, indicator: (any TraceRecordingIndicator)? = nil, secureInput: any TraceSecureInput) {
        self.app = app
        self.daemon = daemon
        self.chromium = chromium
        self.keyFlows = keyFlows
        self.indicator = indicator
        self.secureInput = secureInput
    }
}

/// The app's recording ring.
public protocol TraceAppRecording: Sendable {
    /// Maps the recording ring ahead of a start (blocking file work, run off the caller's thread).
    ///
    /// - Returns: Whether the ring is ready.
    func prepare() async -> Bool
    /// Starts the recording (no disk I/O).
    func start(_ request: TraceRuntime.RecordingRequest) -> TraceRuntime.RecordingStatus
    /// Stops it; the result names the ring's file.
    func stop() -> TraceRuntime.RecordingStatus
    /// The ring's state now.
    var status: TraceRuntime.RecordingStatus { get }
}

/// The daemon's trace commands.
public protocol TraceDaemonLink: Sendable {
    /// Sends `command` and returns the daemon's reply (each process's ring path and bytes).
    func send(_ command: TraceControl.DaemonCommand) async throws -> CmuxNextSettings.JSONValue
}

/// Chromium tracing (task 051).
public protocol TraceChromiumLink: Sendable {
    /// Begins tracing; the reply says where it runs.
    func start() async throws -> CmuxNextSettings.JSONValue
    /// Ends tracing into the recording's folder; the reply names the JSON file.
    func stop() async throws -> CmuxNextSettings.JSONValue
}

/// The typing flows (task 019).
public protocol TraceKeyFlows: Sendable {
    /// Turns the per-key flow ids on or off.
    func setKeyFlows(_ on: Bool)
}

/// The recording indicator (task 133).
public protocol TraceRecordingIndicator: Sendable {
    /// Shows the indicator; its Stop button calls `stop`.
    @MainActor func show(stop: @escaping @Sendable () async -> Void)
    /// Hides it.
    @MainActor func hide()
}
