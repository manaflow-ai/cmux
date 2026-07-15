import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Owns the macOS permission checks and requests used by computer-use settings and onboarding.
///
/// Computer use is driven entirely by the bundled `cmux Computer Use.app` helper,
/// which carries its own bundle id (`com.cmuxterm.computer-use`) and TCC identity.
/// So the Accessibility / Screen Recording grants that matter are the HELPER's,
/// not cmux's. This service reads them by running the helper driver under its own
/// disclaimed identity and asking it (`call check_permissions`) — never by calling
/// `AXIsProcessTrusted()` on cmux itself, which would report the wrong process.
///
/// Only when the helper bundle is absent (a bare-binary fallback that runs the
/// driver in embedded mode under cmux's identity) do the checks fall back to
/// cmux's own TCC.
@MainActor
final class ComputerUsePermissionService {
    /// Display name of the bundled computer-use helper app the user grants
    /// permissions to. Accessibility / Screen Recording appear under this name in
    /// System Settings — separate from cmux.
    static let helperAppName = "cmux Computer Use"

    /// Shared snapshot of the HELPER's TCC status, refreshed by
    /// ``refreshHelperStatus()``. Static so every short-lived service instance
    /// (settings, onboarding, coordinator) reads the same last-known values, and
    /// the synchronous getters below never block the main thread on a subprocess.
    private static var cachedAccessibility = false
    private static var cachedScreenRecording = false

    /// URL of the bundled `cmux Computer Use.app` helper inside cmux.app, when
    /// present. It lives under `Contents/Library/` so onboarding can reveal it in
    /// Finder for drag-and-drop into the System Settings permission lists.
    var helperAppURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/\(Self.helperAppName).app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The helper's driver executable, when the bundle is present and runnable.
    private var helperBinaryURL: URL? {
        guard let helperAppURL else { return nil }
        let bin = helperAppURL.appendingPathComponent("Contents/MacOS/cmux-cua-driver")
        return FileManager.default.isExecutableFile(atPath: bin.path) ? bin : nil
    }

    /// Selects the helper app in Finder so the user can drag it into a System
    /// Settings permission list. No-op until the helper is bundled.
    func revealHelperInFinder() {
        guard let helperAppURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([helperAppURL])
    }

    // Synchronous getters return the last refreshed snapshot of the HELPER's
    // grants. Call ``refreshHelperStatus()`` to update them.
    func accessibilityGranted() -> Bool { Self.cachedAccessibility }
    func screenRecordingGranted() -> Bool { Self.cachedScreenRecording }

    /// Query the helper's real TCC status out of process and update the cache.
    /// Falls back to cmux's own identity only when no helper bundle exists (the
    /// embedded-driver path), where cmux's TCC is the relevant grant.
    @discardableResult
    func refreshHelperStatus() async -> (accessibility: Bool, screenRecording: Bool) {
        if let binary = helperBinaryURL,
           let status = await Self.queryHelper(binary: binary, prompt: false) {
            Self.cachedAccessibility = status.accessibility
            Self.cachedScreenRecording = status.screenRecording
        } else {
            Self.cachedAccessibility = AXIsProcessTrusted()
            Self.cachedScreenRecording = CGPreflightScreenCaptureAccess()
        }
        return (Self.cachedAccessibility, Self.cachedScreenRecording)
    }

    /// Raise the helper's own Accessibility prompt (attributed to
    /// "cmux Computer Use"), then open the pane so the user can toggle it on.
    func requestAccessibility() {
        raiseHelperPromptsAndRefresh()
        openAccessibilitySettings()
    }

    /// Raise the helper's own Screen Recording prompt, then open the pane.
    func requestScreenRecording() {
        raiseHelperPromptsAndRefresh()
        openScreenRecordingSettings()
    }

    /// Ask the helper to request its missing grants under its own identity — this
    /// both raises the system dialogs as "cmux Computer Use" and adds it to the
    /// System Settings permission lists — then refresh the cached status. When no
    /// helper bundle is present the driver runs embedded, so prompt cmux itself.
    private func raiseHelperPromptsAndRefresh() {
        if let binary = helperBinaryURL {
            Task { [weak self] in
                _ = await Self.queryHelper(binary: binary, prompt: true)
                await self?.refreshHelperStatus()
            }
        } else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            _ = CGRequestScreenCaptureAccess()
            Task { [weak self] in await self?.refreshHelperStatus() }
        }
    }

    func openAccessibilitySettings() {
        openSystemSettings(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }

    func openScreenRecordingSettings() {
        openSystemSettings(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }

    private func openSystemSettings(_ deepLink: String) {
        guard let url = URL(string: deepLink) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Run the bundled helper driver under its own disclaimed identity
    /// (`CUA_DRIVER_DISCLAIM=1`) and read the HELPER's real TCC status via
    /// `call check_permissions`. `prompt: true` also raises the helper's own
    /// permission dialogs. Off the main thread; nil on any spawn/parse failure.
    nonisolated private static func queryHelper(
        binary: URL,
        prompt: Bool
    ) async -> (accessibility: Bool, screenRecording: Bool)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runHelper(binary: binary, prompt: prompt))
            }
        }
    }

    nonisolated private static func runHelper(
        binary: URL,
        prompt: Bool
    ) -> (accessibility: Bool, screenRecording: Bool)? {
        let process = Process()
        process.executableURL = binary
        // Point --socket at a unique, non-existent path so `call` never proxies to
        // a listening daemon on the default socket (e.g. a third-party
        // CuaDriver.app at /Applications, which would answer for ITS identity, not
        // ours). With no daemon on this path the tool runs in-process, so the
        // disclaimed helper answers for its own "cmux Computer Use" TCC identity.
        let noProxySocket = NSTemporaryDirectory()
            + "cmux-cua-inprocess-\(UUID().uuidString).sock"
        process.arguments = [
            "call", "check_permissions", "{\"prompt\":\(prompt ? "true" : "false")}",
            "--socket", noProxySocket,
        ]
        // Disclaim so the driver answers for its OWN bundle identity, and strip
        // any inherited driver env that would change that identity.
        var env = ProcessInfo.processInfo.environment
        env["CUA_DRIVER_DISCLAIM"] = "1"
        env.removeValue(forKey: "CUA_DRIVER_EMBEDDED")
        env.removeValue(forKey: "CUA_DRIVER_RS_RESPONSIBILITY_DISCLAIMED")
        env["CUA_DRIVER_RS_TELEMETRY_ENABLED"] = "false"
        env["CUA_DRIVER_RS_UPDATE_CHECK"] = "false"
        process.environment = env

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        // Output is a small JSON object; reading to EOF then waiting cannot
        // deadlock at this size, and the disclaimed child's stdout is inherited
        // through to our pipe.
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let accessibility = obj["accessibility"] as? Bool ?? false
        let screenRecording = obj["screen_recording"] as? Bool ?? false
        return (accessibility, screenRecording)
    }
}
