import Foundation

/// Every user-facing string of the permission card, localized.
struct PermissionStrings {
    func title(_ kind: PermissionKind) -> String {
        switch kind {
        case .fullDiskAccess: String(localized: "agentPermissions.title.full_disk_access", defaultValue: "Allow Full Disk Access?", bundle: .localizedModule)
        case .accessibility: String(localized: "agentPermissions.title.accessibility", defaultValue: "Allow Accessibility?", bundle: .localizedModule)
        case .screenRecording: String(localized: "agentPermissions.title.screen_recording", defaultValue: "Allow Screen Recording?", bundle: .localizedModule)
        case .automation: String(localized: "agentPermissions.title.automation", defaultValue: "Allow controlling another app?", bundle: .localizedModule)
        case .camera: String(localized: "agentPermissions.title.camera", defaultValue: "Allow the camera?", bundle: .localizedModule)
        case .microphone: String(localized: "agentPermissions.title.microphone", defaultValue: "Allow the microphone?", bundle: .localizedModule)
        case .computerUse: String(localized: "agentPermissions.title.computer_use", defaultValue: "Allow computer use?", bundle: .localizedModule)
        }
    }

    func summary(_ kind: PermissionKind) -> String {
        switch kind {
        case .fullDiskAccess:
            String(localized: "agentPermissions.summary.full_disk_access",
                   defaultValue: "Lets cmux read files macOS protects, like Mail, Messages and other apps’ data.", bundle: .localizedModule)
        case .accessibility:
            String(localized: "agentPermissions.summary.accessibility", defaultValue: "Lets agents click, type and scroll in other apps.",
                   bundle: .localizedModule)
        case .screenRecording:
            String(localized: "agentPermissions.summary.screen_recording", defaultValue: "Lets agents see the windows they work in.",
                   bundle: .localizedModule)
        case .automation:
            String(localized: "agentPermissions.summary.automation", defaultValue: "Lets agents send commands to one other app.", bundle: .localizedModule)
        case .camera: String(localized: "agentPermissions.summary.camera", defaultValue: "Lets cmux use the camera.", bundle: .localizedModule)
        case .microphone: String(localized: "agentPermissions.summary.microphone", defaultValue: "Lets cmux use the microphone.", bundle: .localizedModule)
        case .computerUse:
            String(localized: "agentPermissions.summary.computer_use",
                   defaultValue: "Lets agents see and use your apps. macOS needs two permissions for it.", bundle: .localizedModule)
        }
    }

    func agentLine(_ requester: PermissionRequester) -> String {
        guard let workspace = requester.workspaceName, !workspace.isEmpty else { return requester.agentName }
        return String(format: String(localized: "agentPermissions.agentInWorkspace", defaultValue: "%1$@ in %2$@", bundle: .localizedModule),
                      requester.agentName, workspace)
    }

    var claimed: String { String(localized: "agentPermissions.claimed", defaultValue: "name given by the agent", bundle: .localizedModule) }
    var why: String { String(localized: "agentPermissions.why", defaultValue: "Why", bundle: .localizedModule) }
    var youAsked: String { String(localized: "agentPermissions.youAsked", defaultValue: "You asked", bundle: .localizedModule) }
    var noPrompt: String { String(localized: "agentPermissions.noPrompt", defaultValue: "No request from you is linked.", bundle: .localizedModule) }
    var unclear: String {
        String(localized: "agentPermissions.unclear",
               defaultValue: "This reason does not clearly match what you asked. Deny if you did not expect this.", bundle: .localizedModule)
    }
    var deny: String { String(localized: "agentPermissions.deny", defaultValue: "Deny", bundle: .localizedModule) }
    var proceed: String { String(localized: "agentPermissions.continue", defaultValue: "Continue", bundle: .localizedModule) }
    var close: String { String(localized: "agentPermissions.done", defaultValue: "Close", bundle: .localizedModule) }
    var granted: String { String(localized: "agentPermissions.granted", defaultValue: "Granted", bundle: .localizedModule) }
    var promptGuide: String {
        String(localized: "agentPermissions.guide.prompt", defaultValue: "Answer the macOS prompt to finish.", bundle: .localizedModule)
    }

    func dragGuide(_ appName: String) -> String {
        String(format: String(localized: "agentPermissions.guide.drag",
                              defaultValue: "Drag %@ into the list in System Settings, then turn it on.", bundle: .localizedModule), appName)
    }

    func more(_ count: Int) -> String {
        String(format: String(localized: "agentPermissions.more", defaultValue: "%d more waiting", bundle: .localizedModule), count)
    }
}
