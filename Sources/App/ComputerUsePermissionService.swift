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
    /// The bundled helper's `.app` DIRECTORY name inside cmux.app. Constant
    /// across release and dev/tagged builds so fixed lookup paths (here and in the
    /// agent wrappers) keep resolving. The user-facing name shown in System
    /// Settings can differ per build — read it via ``helperDisplayName``.
    static let helperAppName = "cmux Computer Use"

    /// Shared snapshot of the HELPER's TCC status, refreshed by
    /// ``refreshHelperStatus()``. Static so every short-lived service instance
    /// (settings, onboarding, coordinator) reads the same last-known values, and
    /// the synchronous getters below never block the main thread on a subprocess.
    private static var cachedAccessibility = false
    private static var cachedScreenRecording = false

    /// The bundled helper nested inside cmux.app at `Contents/Library/`. This is
    /// the SOURCE we copy from — it is NOT what the running daemon uses, and it
    /// must not be revealed for drag-and-drop: Finder can't navigate into a
    /// `.app` bundle, so a nested path is undraggable.
    private var nestedHelperAppURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/\(Self.helperAppName).app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The directory the agent wrappers install the STANDALONE helper into — the
    /// exact copy the wrappers launch via LaunchServices as the serve daemon.
    /// Kept in sync with `cmux_computer_use_standalone_helper` in the wrappers.
    private static var standaloneHelperDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/cmux/computer-use/helper", isDirectory: true)
    }

    /// The standalone helper `.app` the daemon actually runs as, at a clean,
    /// user-revealable path outside any `.app` bundle. This is the ONE identity
    /// onboarding must reveal, drag, and status-check against, so the grant the
    /// user makes lands on the process the daemon runs.
    private static var standaloneHelperAppURL: URL {
        standaloneHelperDirectory.appendingPathComponent("\(helperAppName).app")
    }

    /// URL of the `cmux Computer Use.app` helper to surface in onboarding
    /// (reveal / drag / icon). Prefers the installed STANDALONE copy — the same
    /// bundle the daemon runs and the only one at a Finder-draggable path — and
    /// falls back to the nested bundle only when the standalone isn't installed
    /// yet (e.g. before the first computer-use call). Call
    /// ``ensureStandaloneHelperInstalled()`` first so this returns the standalone.
    var helperAppURL: URL? {
        let standaloneBinary = Self.standaloneHelperAppURL
            .appendingPathComponent("Contents/MacOS/cmux-cua-driver")
        if FileManager.default.isExecutableFile(atPath: standaloneBinary.path) {
            return Self.standaloneHelperAppURL
        }
        return nestedHelperAppURL
    }

    /// Install (or refresh) the standalone helper from the nested bundle so
    /// onboarding, the status check, and the daemon all reference ONE bundle at
    /// ONE path. Mirrors the wrappers' `cmux_computer_use_standalone_helper`:
    /// `ditto` (preserving the ad-hoc signature) into
    /// `~/Library/Application Support/cmux/computer-use/helper`, re-syncing only
    /// when the nested driver is newer. Returns the standalone URL, or the nested
    /// URL if the copy can't be made. No-op fast path when already current.
    @discardableResult
    func ensureStandaloneHelperInstalled() -> URL? {
        guard let nested = nestedHelperAppURL else { return nil }
        let fm = FileManager.default
        let dest = Self.standaloneHelperAppURL
        let nestedBin = nested.appendingPathComponent("Contents/MacOS/cmux-cua-driver")
        let destBin = dest.appendingPathComponent("Contents/MacOS/cmux-cua-driver")

        // Fast path: an up-to-date standalone copy already exists.
        if fm.isExecutableFile(atPath: destBin.path) {
            let nestedDate = (try? nestedBin.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let destDate = (try? destBin.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let n = nestedDate, let d = destDate, n <= d {
                return dest
            }
            if nestedDate == nil || destDate == nil {
                return dest
            }
        }

        do {
            try fm.createDirectory(at: Self.standaloneHelperDirectory, withIntermediateDirectories: true)
        } catch {
            return nested
        }

        // ditto preserves the ad-hoc signature, xattrs, and symlinks a bundle
        // needs to stay TCC-valid (plain copyItem can drop them). Copy to a temp
        // path then atomically swap so a concurrent install never sees a partial.
        let tmp = Self.standaloneHelperDirectory
            .appendingPathComponent(".\(Self.helperAppName).tmp.\(ProcessInfo.processInfo.processIdentifier).app")
        try? fm.removeItem(at: tmp)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = [nested.path, tmp.path]
        do {
            try ditto.run()
            ditto.waitUntilExit()
        } catch {
            try? fm.removeItem(at: tmp)
            return nested
        }
        guard ditto.terminationStatus == 0 else {
            try? fm.removeItem(at: tmp)
            return fm.isExecutableFile(atPath: destBin.path) ? dest : nested
        }
        try? fm.removeItem(at: dest)
        do {
            try fm.moveItem(at: tmp, to: dest)
        } catch {
            try? fm.removeItem(at: tmp)
            return fm.isExecutableFile(atPath: destBin.path) ? dest : nested
        }
        return dest
    }

    /// The helper's actual user-facing name, read from its bundle so onboarding
    /// text matches exactly what the user sees in System Settings — including the
    /// dev/tagged suffix a non-release cmux gives its helper (e.g.
    /// "cmux DEV my-tag Computer Use"). Falls back to the directory name.
    var helperDisplayName: String {
        guard
            let helperAppURL,
            let plist = NSDictionary(
                contentsOf: helperAppURL.appendingPathComponent("Contents/Info.plist")
            ),
            let name = (plist["CFBundleDisplayName"] ?? plist["CFBundleName"]) as? String,
            !name.isEmpty
        else { return Self.helperAppName }
        return name
    }

    /// The helper's driver executable, when the bundle is present and runnable.
    /// Resolves through ``helperAppURL`` so it targets the STANDALONE copy the
    /// daemon runs — the status check then reads the SAME TCC identity the user
    /// grants, so a grant actually shows up as "granted" in onboarding.
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
        // Install the standalone helper first so the status probe below runs the
        // SAME bundle the daemon runs — otherwise a grant on the daemon's
        // identity would never register here and onboarding would never advance.
        ensureStandaloneHelperInstalled()
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

    /// Guide the user to grant the HELPER Accessibility: open the pane and reveal
    /// the helper in Finder so they can drag it into the list. This deliberately
    /// does NOT raise a system prompt: the only process that can request a grant
    /// for the helper's identity is the helper itself, and a short-lived probe
    /// exits before macOS shows the async dialog — so the prompt would misattribute
    /// to cmux. Dragging the helper bundle in adds ITS identity, and a real
    /// computer-use session (a long-lived helper) prompts under its own name.
    /// cmux never requests computer-use permissions for its own identity.
    func requestAccessibility() {
        openAccessibilitySettings()
        revealHelperInFinder()
    }

    /// Guide the user to grant the HELPER Screen Recording (see
    /// ``requestAccessibility()`` for why this uses drag-drop, not a prompt).
    func requestScreenRecording() {
        openScreenRecordingSettings()
        revealHelperInFinder()
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
