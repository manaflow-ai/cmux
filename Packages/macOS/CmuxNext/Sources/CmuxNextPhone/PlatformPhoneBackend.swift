public import Foundation

/// The app's one ``PhoneBackend``: iOS phones go to ``XcodePhoneBackend``,
/// Android phones to ``AndroidPhoneBackend``. A Mac without Xcode or without
/// the Android SDK still lists the other platform, and ``missingTools`` says
/// what is missing so the phone tab can show how to get it.
public actor PlatformPhoneBackend: PhoneBackend {
    private let ios: XcodePhoneBackend
    private let android: AndroidPhoneBackend?
    /// The tools the last ``devices()`` call found missing.
    public private(set) var missingTools: Set<PhoneTool> = []

    /// - Parameter android: nil when no Android SDK is installed (``AndroidSDK/locate(environment:home:fileExists:)``).
    public init(ios: XcodePhoneBackend, android: AndroidPhoneBackend?) {
        self.ios = ios
        self.android = android
        if android == nil { missingTools = [.androidSDK] }
    }

    public func devices() async throws -> [PhoneDevice] {
        var missing: Set<PhoneTool> = android == nil ? [.androidSDK] : []
        var phones: [PhoneDevice] = []
        var firstError: (any Error)?
        do { phones += try await ios.devices() } catch {
            missing.insert(.xcode)
            firstError = error
        }
        if let android {
            do { phones += try await android.devices() } catch {
                firstError = firstError ?? error
            }
        }
        missingTools = missing
        // Fail only when no platform answered; one broken platform must not hide the other.
        if phones.isEmpty, let firstError, android != nil || !missing.contains(.xcode) { throw firstError }
        return phones
    }

    public nonisolated func capabilities(for device: PhoneDevice) -> PhoneCapabilities {
        device.mode.isAndroid ? (android?.capabilities(for: device) ?? []) : ios.capabilities(for: device)
    }

    public func boot(_ id: PhoneDeviceID) async throws { try await route(id).boot(id) }
    public func shutdown(_ id: PhoneDeviceID) async throws { try await route(id).shutdown(id) }
    public func screenshot(_ id: PhoneDeviceID, to file: URL) async throws { try await route(id).screenshot(id, to: file) }

    public nonisolated func videoExtension(for id: PhoneDeviceID) -> String {
        id.mode.isAndroid ? "mp4" : ios.videoExtension(for: id)
    }

    public func startVideo(_ id: PhoneDeviceID, to file: URL) async throws -> any PhoneRunningCommand {
        try await route(id).startVideo(id, to: file)
    }

    public func startLog(_ id: PhoneDeviceID, to file: URL) async throws -> (any PhoneRunningCommand)? {
        try await route(id).startLog(id, to: file)
    }

    public func send(_ input: PhoneInput, to id: PhoneDeviceID) async throws { try await route(id).send(input, to: id) }

    public func accessibilityTree(_ id: PhoneDeviceID) async throws -> PhoneElement {
        try await route(id).accessibilityTree(id)
    }

    public func screenPoints(_ id: PhoneDeviceID) async throws -> PhonePoint {
        try await route(id).screenPoints(id)
    }

    public func logCommand(_ id: PhoneDeviceID) async throws -> [String] {
        try await route(id).logCommand(id)
    }

    /// The `adb` path and serial for an Android phone's live screen.
    public func androidStreamTarget(_ id: PhoneDeviceID) async throws -> (adb: String, serial: String) {
        guard id.mode.isAndroid, let android else { throw PhoneError.missingTool(.androidSDK) }
        return try await android.streamTarget(id)
    }

    /// Turns an Android emulator a quarter turn.
    public func rotate(_ id: PhoneDeviceID) async throws {
        try await rotate(id, .right)
    }

    /// Turns an Android emulator a quarter turn left or right (iOS rotation comes later).
    public func rotate(_ id: PhoneDeviceID, _ direction: PhoneRotation) async throws {
        guard id.mode.isAndroid, let android else { throw PhoneError.unsupported(mode: id.mode, what: "rotate") }
        try await android.rotate(id, direction)
    }

    public func appearance(_ id: PhoneDeviceID) async throws -> PhoneAppearance {
        try await route(id).appearance(id)
    }

    private func route(_ id: PhoneDeviceID) throws -> any PhoneBackend {
        guard id.mode.isAndroid else { return ios }
        guard let android else { throw PhoneError.missingTool(.androidSDK) }
        return android
    }
}
