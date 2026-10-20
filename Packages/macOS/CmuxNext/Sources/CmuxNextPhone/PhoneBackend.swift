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
}

/// Why a phone call failed. `description` is shown to people and agents.
public enum PhoneError: Error, Sendable, Hashable, CustomStringConvertible {
    case unknownDevice(String)
    case unsupported(mode: PhoneMode, what: String)
    case commandFailed(command: String, status: Int32, stderr: String)
    case notRecording
    case alreadyRecording

    public var description: String {
        switch self {
        case .unknownDevice(let id): "no phone \(id)"
        case .unsupported(let mode, let what): "\(what) is not available for \(mode.rawValue) phones yet"
        case .commandFailed(let command, let status, let stderr):
            "\(command) failed (\(status))" + (stderr.isEmpty ? "" : ": \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        case .notRecording: "no recording is running"
        case .alreadyRecording: "a recording is already running"
        }
    }
}
