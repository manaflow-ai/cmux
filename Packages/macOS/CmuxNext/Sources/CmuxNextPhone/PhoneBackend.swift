public import Foundation

/// Lists and drives phones of one or more modes. ``XcodePhoneBackend`` serves
/// simulators and real devices; a VM backend can join later behind the same
/// shape (plans/cmux-next/phone.md).
public protocol PhoneBackend: Sendable {
    func devices() async throws -> [PhoneDevice]
    func capabilities(for device: PhoneDevice) -> PhoneCapabilities
    func boot(_ id: PhoneDeviceID) async throws
    func shutdown(_ id: PhoneDeviceID) async throws
    /// Writes a PNG of the screen to `file`.
    func screenshot(_ id: PhoneDeviceID, to file: URL) async throws
    /// The file extension the backend's screen recordings use ("mov", "mp4").
    func videoExtension(for id: PhoneDeviceID) -> String
    /// Starts recording the screen into `file`; interrupt the handle to stop.
    func startVideo(_ id: PhoneDeviceID, to file: URL) async throws -> any PhoneRunningCommand
    /// Starts streaming the device log as NDJSON into `file`; nil when the
    /// mode has no log stream.
    func startLog(_ id: PhoneDeviceID, to file: URL) async throws -> (any PhoneRunningCommand)?
    func send(_ input: PhoneInput, to id: PhoneDeviceID) async throws
    /// The screen's accessibility tree, frames in device points.
    func accessibilityTree(_ id: PhoneDeviceID) async throws -> PhoneElement
    /// The screen size in the points taps use (iOS points, Android dp), current orientation.
    func screenPoints(_ id: PhoneDeviceID) async throws -> PhonePoint
    /// The argv that streams the device log to a terminal (`cmux phone logs` opens it in a terminal tab).
    func logCommand(_ id: PhoneDeviceID) async throws -> [String]
    /// The system appearance the phone shows now.
    func appearance(_ id: PhoneDeviceID) async throws -> PhoneAppearance
}

extension PhoneBackend {
    public func screenPoints(_ id: PhoneDeviceID) async throws -> PhonePoint {
        throw PhoneError.unsupported(mode: id.mode, what: "touch")
    }

    public func logCommand(_ id: PhoneDeviceID) async throws -> [String] {
        throw PhoneError.unsupported(mode: id.mode, what: "logs")
    }

    public func accessibilityTree(_ id: PhoneDeviceID) async throws -> PhoneElement {
        throw PhoneError.unsupported(mode: id.mode, what: "the accessibility tree")
    }

    public func appearance(_ id: PhoneDeviceID) async throws -> PhoneAppearance {
        throw PhoneError.unsupported(mode: id.mode, what: "appearance")
    }
}

/// Why a phone call failed. `description` is shown to people and agents.
public enum PhoneError: Error, Sendable, Hashable, CustomStringConvertible {
    case unknownDevice(String)
    case unsupported(mode: PhoneMode, what: String)
    case commandFailed(command: String, status: Int32, stderr: String)
    case notRecording
    case alreadyRecording
    /// The phone is listed but not running (a shut-down emulator).
    case notRunning(String)
    /// The developer tool this phone mode needs is not installed.
    case missingTool(PhoneTool)
    /// A tap or swipe point is outside the phone's screen.
    case outsideScreen
    /// The tool answered something cmux could not read.
    case unreadable(what: String)
    /// A number no phone input or recording can have (a swipe longer than ``PhoneInput/longestSwipe``).
    case outOfRange(what: String)

    public var description: String {
        switch self {
        case .unknownDevice(let id): "no phone \(id)"
        case .unsupported(let mode, let what): "\(what) is not available for \(mode.rawValue) phones yet"
        case .commandFailed(let command, let status, let stderr):
            "\(command) failed (\(status))" + (stderr.isEmpty ? "" : ": \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        case .notRecording: "no recording is running"
        case .alreadyRecording: "a recording is already running"
        case .notRunning(let id): "\(id) is not running; boot it first"
        case .missingTool(.xcode): "Xcode is not installed; install it from the App Store for iOS simulators"
        case .missingTool(.androidSDK):
            "the Android SDK is not installed; install Android Studio or set ANDROID_HOME for Android emulators"
        case .unreadable(let what): "could not read \(what)"
        case .outsideScreen: "that point is outside the phone's screen"
        case .outOfRange(let what): "\(what) is out of range"
        }
    }
}
