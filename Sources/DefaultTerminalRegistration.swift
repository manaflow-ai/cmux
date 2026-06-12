import AppKit
import CmuxSocketControl
import Bonsplit
import Foundation
import UniformTypeIdentifiers


// MARK: - Default Terminal Registration
extension Notification.Name {
    static let defaultTerminalRegistrationDidChange = Notification.Name("DefaultTerminalRegistration.didChange")
}

struct DefaultTerminalRegistrationStatus: Equatable {
    let matchedTargetCount: Int
    let targetCount: Int

    var isDefault: Bool {
        matchedTargetCount == targetCount
    }
}

enum DefaultTerminalRegistrationError: Error, LocalizedError {
    case launchServicesRegistrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .launchServicesRegistrationFailed:
            return String(
                localized: "error.defaultTerminal.registrationFailed",
                defaultValue: "cmux could not register as the default terminal app."
            )
        }
    }
}

enum DefaultTerminalRegistration {
    static let urlSchemes = ["ssh"]
    static let contentTypeIdentifiers = [
        "com.apple.terminal.shell-script",
        "public.unix-executable"
    ]

    static func contentType(forIdentifier identifier: String) -> UTType {
        UTType(identifier) ?? UTType(importedAs: identifier)
    }

    static var targetCount: Int {
        urlSchemes.count + contentTypeIdentifiers.count
    }

    static func currentStatus(
        bundleURL: URL = Bundle.main.bundleURL,
        workspace: NSWorkspace = .shared
    ) -> DefaultTerminalRegistrationStatus {
        let normalizedBundleURL = normalizedApplicationURL(bundleURL)
        let matchedURLSchemes = urlSchemes.filter { scheme in
            guard let url = URL(string: "\(scheme)://cmux-default-terminal-check") else {
                return false
            }
            return normalizedApplicationURL(workspace.urlForApplication(toOpen: url)) == normalizedBundleURL
        }.count

        let matchedContentTypes = contentTypeIdentifiers.filter { identifier in
            let contentType = contentType(forIdentifier: identifier)
            return normalizedApplicationURL(workspace.urlForApplication(toOpen: contentType)) == normalizedBundleURL
        }.count

        return DefaultTerminalRegistrationStatus(
            matchedTargetCount: matchedURLSchemes + matchedContentTypes,
            targetCount: targetCount
        )
    }

    static func setAsDefault(bundleURL: URL = Bundle.main.bundleURL) async throws {
        let normalizedBundleURL = normalizedApplicationURL(bundleURL) ?? bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        var didAttemptHandlerUpdate = false
        defer {
            if didAttemptHandlerUpdate {
                Task { @MainActor in
                    NotificationCenter.default.post(name: .defaultTerminalRegistrationDidChange, object: nil)
                }
            }
        }

        let registerStatus = LSRegisterURL(normalizedBundleURL as CFURL, true)
        guard registerStatus == noErr else {
            throw DefaultTerminalRegistrationError.launchServicesRegistrationFailed(registerStatus)
        }
        didAttemptHandlerUpdate = true

        for scheme in urlSchemes {
            try await NSWorkspace.shared.setDefaultApplication(
                at: normalizedBundleURL,
                toOpenURLsWithScheme: scheme
            )
        }

        for identifier in contentTypeIdentifiers {
            let contentType = contentType(forIdentifier: identifier)
            try await NSWorkspace.shared.setDefaultApplication(
                at: normalizedBundleURL,
                toOpen: contentType
            )
        }
    }

    private static func normalizedApplicationURL(_ url: URL?) -> URL? {
        url?.standardizedFileURL.resolvingSymlinksInPath()
    }
}

@MainActor
enum DefaultTerminalUserAction {
    private struct RegistrationOperation {
        let id: UUID
        let task: Task<Void, Error>
    }

    private static var inFlightRegistration: RegistrationOperation?

    @discardableResult
    private static func registerAsDefault() async throws -> Bool {
        if let operation = inFlightRegistration {
            do {
                try await operation.task.value
            } catch {
                return false
            }
            return false
        }

        let operation = RegistrationOperation(
            id: UUID(),
            task: Task {
                try await DefaultTerminalRegistration.setAsDefault()
            }
        )
        inFlightRegistration = operation

        do {
            try await operation.task.value
            if inFlightRegistration?.id == operation.id {
                inFlightRegistration = nil
            }
            return true
        } catch {
            if inFlightRegistration?.id == operation.id {
                inFlightRegistration = nil
            }
            throw error
        }
    }

    static func setAsDefault(debugSource: String) {
#if DEBUG
        cmuxDebugLog("defaultTerminal.setAsDefault source=\(debugSource)")
#endif
        Task {
            do {
                try await registerAsDefault()
            } catch {
#if DEBUG
                cmuxDebugLog("defaultTerminal.setAsDefault.failed source=\(debugSource) error=\(error)")
#endif
                presentSetAsDefaultError(error)
            }
        }
    }

    private static func presentSetAsDefaultError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "dialog.defaultTerminal.setFailed.title",
            defaultValue: "Could Not Set Default Terminal"
        )
        alert.informativeText = (error as? DefaultTerminalRegistrationError)?.errorDescription ?? String(
            localized: "defaultTerminal.updateFailed.message",
            defaultValue: "macOS could not update every default terminal handler."
        )
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.window.identifier = NSUserInterfaceItemIdentifier("cmux.defaultTerminalRegistrationError")
        alert.runModal()
    }
}

