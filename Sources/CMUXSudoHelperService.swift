import Foundation
import ServiceManagement
import os

nonisolated private let cmuxSudoHelperServiceLogger = Logger(subsystem: "com.cmuxterm.app", category: "sudo-helper-service")

struct CMUXSudoHelperServiceResult: Sendable {
    let available: Bool
    let errorCode: String?
    let message: String?

    static let available = CMUXSudoHelperServiceResult(available: true, errorCode: nil, message: nil)

    static func unavailable(errorCode: String, message: String) -> CMUXSudoHelperServiceResult {
        CMUXSudoHelperServiceResult(available: false, errorCode: errorCode, message: message)
    }
}

enum CMUXSudoHelperService {
    static let plistName = "com.cmuxterm.sudo-helper.plist"

    static func ensureRegistered(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> CMUXSudoHelperServiceResult {
        guard #available(macOS 13.0, *) else {
            return unavailable("helper_unsupported")
        }

        let plistURL = bundle.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
            .appendingPathComponent(plistName, isDirectory: false)
        guard fileManager.fileExists(atPath: plistURL.path) else {
            cmuxSudoHelperServiceLogger.error("sudo.helper.service.plist_missing path=\(plistURL.path, privacy: .private)")
            return unavailable("helper_not_bundled")
        }

        let service = SMAppService.daemon(plistName: plistName)
        switch service.status {
        case .enabled:
            return .available
        case .notRegistered:
            do {
                try service.register()
            } catch {
                cmuxSudoHelperServiceLogger.error("sudo.helper.service.register_failed error=\(String(describing: error), privacy: .private)")
                return unavailable("helper_registration_failed")
            }
            return statusResult(service.status)
        case .requiresApproval, .notFound:
            return statusResult(service.status)
        @unknown default:
            return unavailable("helper_status_unknown")
        }
    }

    @available(macOS 13.0, *)
    private static func statusResult(_ status: SMAppService.Status) -> CMUXSudoHelperServiceResult {
        switch status {
        case .enabled:
            return .available
        case .requiresApproval:
            return .unavailable(
                errorCode: "helper_requires_approval",
                message: String(
                    localized: "sudo.helper.requiresApproval",
                    defaultValue: "Approve the cmux sudo helper in System Settings, then retry. No command was run."
                )
            )
        case .notFound:
            return unavailable("helper_not_found")
        case .notRegistered:
            return unavailable("helper_not_registered")
        @unknown default:
            return unavailable("helper_status_unknown")
        }
    }

    private static func unavailable(_ errorCode: String) -> CMUXSudoHelperServiceResult {
        .unavailable(
            errorCode: errorCode,
            message: String(
                localized: "sudo.helper.unavailable",
                defaultValue: "The cmux sudo helper is not installed or enabled. No command was run."
            )
        )
    }
}
