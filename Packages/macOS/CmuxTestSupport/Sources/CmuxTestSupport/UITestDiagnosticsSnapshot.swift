public import Foundation

/// A point-in-time, `Sendable` snapshot of the live app state that the
/// display/render/socket/portal UI-test diagnostics payload is assembled
/// from.
///
/// The diagnostics recorder (``DisplayDiagnosticsUITestRecorder``) turns this
/// snapshot into the byte-identical `[String: String]` JSON the
/// `CMUX_UI_TEST_DIAGNOSTICS_PATH` XCUITest scenario reads. All live-state
/// reads (NSApp windows, `NSScreen` display IDs, the socket health probe, the
/// terminal render stats, and the portal-registry stats) happen on the main
/// actor inside the app-target ``UITestDiagnosticsProviding`` conformer, which
/// hands the resulting plain values here so the recorder stays free of
/// AppKit/`TerminalController`/portal references.
///
/// The provider already applies each section's environment gate: a `nil`
/// ``socket``/``render``/``portal`` means "section not requested or
/// unavailable", so the recorder emits exactly the keys the legacy
/// `AppDelegate` implementation did for that case.
public struct UITestDiagnosticsSnapshot: Sendable {
    /// One open `NSWindow`'s identity and placement, in `NSApp.windows` order.
    public struct Window: Sendable {
        /// The window's `identifier?.rawValue`, or `""` when unset.
        public let identifier: String
        /// Whether the window `isVisible`.
        public let isVisible: Bool
        /// The window's screen's `cmuxDisplayID`, or `nil` when unresolved.
        public let screenDisplayID: UInt32?

        /// Creates a window descriptor.
        public init(identifier: String, isVisible: Bool, screenDisplayID: UInt32?) {
            self.identifier = identifier
            self.isVisible = isVisible
            self.screenDisplayID = screenDisplayID
        }
    }

    /// The terminal render-stats section's state when
    /// `CMUX_UI_TEST_DISPLAY_RENDER_STATS=1`.
    ///
    /// A `nil` ``UITestDiagnosticsSnapshot/render`` means the gate is unset
    /// (no render keys emitted at all). ``unavailable`` means the gate is set
    /// but no focused terminal panel exists (the legacy `renderStatsAvailable`
    /// `"0"` empty-value shape). ``available`` carries the live stats.
    public enum Render: Sendable {
        case unavailable
        case available(Stats)
    }

    /// The live terminal render stats.
    public struct Stats: Sendable {
        public let panelID: UUID
        public let drawCount: Int
        public let presentCount: Int
        public let lastPresentTime: Double
        public let windowVisible: Bool
        public let appIsActive: Bool
        public let desiredFocus: Bool
        public let isFirstResponder: Bool

        /// Creates a render-stats section.
        public init(
            panelID: UUID,
            drawCount: Int,
            presentCount: Int,
            lastPresentTime: Double,
            windowVisible: Bool,
            appIsActive: Bool,
            desiredFocus: Bool,
            isFirstResponder: Bool
        ) {
            self.panelID = panelID
            self.drawCount = drawCount
            self.presentCount = presentCount
            self.lastPresentTime = lastPresentTime
            self.windowVisible = windowVisible
            self.appIsActive = appIsActive
            self.desiredFocus = desiredFocus
            self.isFirstResponder = isFirstResponder
        }
    }

    /// The socket-sanity section, present only when
    /// `CMUX_UI_TEST_SOCKET_SANITY=1`.
    public struct Socket: Sendable {
        /// When `false`, the socket is disabled and only the disabled-shape
        /// keys (`socketExpectedPath` from `CMUX_SOCKET_PATH`, `socketMode`
        /// `"off"`, all-zero flags, `socketFailureSignals` `"socket_disabled"`)
        /// are emitted.
        public let isEnabled: Bool
        /// `CMUX_SOCKET_PATH` when disabled, else the resolved active path.
        public let expectedPath: String
        /// The control-socket mode raw value, or `"off"` when disabled.
        public let mode: String
        public let isReady: Bool
        public let pingResponse: String
        public let isRunning: Bool
        public let acceptLoopAlive: Bool
        public let socketPathMatches: Bool
        public let socketPathExists: Bool
        public let socketPathOwnedByListener: Bool
        /// Comma-joined failure signals.
        public let failureSignals: String

        /// Creates a socket-sanity section.
        public init(
            isEnabled: Bool,
            expectedPath: String,
            mode: String,
            isReady: Bool,
            pingResponse: String,
            isRunning: Bool,
            acceptLoopAlive: Bool,
            socketPathMatches: Bool,
            socketPathExists: Bool,
            socketPathOwnedByListener: Bool,
            failureSignals: String
        ) {
            self.isEnabled = isEnabled
            self.expectedPath = expectedPath
            self.mode = mode
            self.isReady = isReady
            self.pingResponse = pingResponse
            self.isRunning = isRunning
            self.acceptLoopAlive = acceptLoopAlive
            self.socketPathMatches = socketPathMatches
            self.socketPathExists = socketPathExists
            self.socketPathOwnedByListener = socketPathOwnedByListener
            self.failureSignals = failureSignals
        }

        /// The disabled-socket section, mirroring the legacy "socket off"
        /// branch.
        ///
        /// - Parameter expectedPath: The `CMUX_SOCKET_PATH` value (or `""`).
        public static func disabled(expectedPath: String) -> Socket {
            Socket(
                isEnabled: false,
                expectedPath: expectedPath,
                mode: "off",
                isReady: false,
                pingResponse: "",
                isRunning: false,
                acceptLoopAlive: false,
                socketPathMatches: false,
                socketPathExists: false,
                socketPathOwnedByListener: false,
                failureSignals: "socket_disabled"
            )
        }
    }

    /// `pid` from `ProcessInfo.processIdentifier`.
    public let processIdentifier: Int32
    /// `Bundle.main.bundleIdentifier`, or `""`.
    public let bundleIdentifier: String
    /// Whether the process is running under XCTest.
    public let isRunningUnderXCTest: Bool
    /// The open windows in `NSApp.windows` order.
    public let windows: [Window]
    /// `CMUX_UI_TEST_TARGET_DISPLAY_ID`, or `""`.
    public let targetDisplayID: String
    /// The set of `cmuxDisplayID`s across `NSScreen.screens`, used to compute
    /// `targetDisplayPresent`.
    public let presentDisplayIDs: Set<UInt32>
    /// The render-stats section, or `nil` when
    /// `CMUX_UI_TEST_DISPLAY_RENDER_STATS` is not set.
    public let render: Render?
    /// The socket-sanity section, or `nil` when `CMUX_UI_TEST_SOCKET_SANITY`
    /// is not set.
    public let socket: Socket?
    /// The flattened portal-stats keys (already prefixed with `portal_`), or
    /// `nil` when `CMUX_UI_TEST_PORTAL_STATS` is not set. Flattening happens
    /// app-side because the registry returns an untyped `[String: Any]`.
    public let portal: [String: String]?
    /// `ProcessInfo.systemUptime`, formatted as `%.6f` for
    /// `renderDiagnosticsUpdatedAt` when the render section is requested.
    public let systemUptime: Double

    /// Creates a diagnostics snapshot.
    public init(
        processIdentifier: Int32,
        bundleIdentifier: String,
        isRunningUnderXCTest: Bool,
        windows: [Window],
        targetDisplayID: String,
        presentDisplayIDs: Set<UInt32>,
        render: Render?,
        socket: Socket?,
        portal: [String: String]?,
        systemUptime: Double
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.isRunningUnderXCTest = isRunningUnderXCTest
        self.windows = windows
        self.targetDisplayID = targetDisplayID
        self.presentDisplayIDs = presentDisplayIDs
        self.render = render
        self.socket = socket
        self.portal = portal
        self.systemUptime = systemUptime
    }
}
