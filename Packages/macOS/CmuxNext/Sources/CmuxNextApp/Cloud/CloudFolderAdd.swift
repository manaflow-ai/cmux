import AppKit
import CmuxNextCloudPlace
import CmuxNextSettings
import Foundation

/// Sources > Add Folder on a running Cloud chat (`cloud.folder.add`, setting `cloud.addFolderLive`,
/// on by default). Leo, 2026-11-25: "mostly just the one you selected, right? then you can add more
/// folders and files/select more as you go potentially". The person picks a Mac folder; one Rust
/// call (`cmux link access grant --attach`) refuses what may never go (outside the home folder, dot
/// and credential folders, ~/Library), copies it read-only to the chat's machine, skipping secret
/// files, and puts the copy among the chat's folders there (`chat-folder-add`, acpmux
/// `_acpmux/set_directories`, between turns). The chat draws the line ("Added ~/x as /vm/path")
/// from acpmux's record; a failure comes back as the reply's reason, which the page shows in the
/// chat, and nothing is added.
@MainActor
enum CloudFolderAdd {
    /// Whether chat tab `tab` offers Add Folder now: the setting is on and the tab is a Cloud chat on
    /// a connected machine.
    static func offered(tab: String, services: AppServices) -> Bool {
        isOn(services) && CloudUploads.target(tab: tab, services: services) != nil
    }

    static func isOn(_ services: AppServices) -> Bool {
        CloudNewWorkspaceSetting().addFolderLive(in: services.settings?.snapshot.root ?? .object([:]))
    }

    /// The person's Add Folder click on chat tab `tab` showing `session`: `{applied, path, from}`,
    /// `applied` "cancelled" when no folder was picked.
    static func run(tab: String, session: String, services: AppServices) async throws -> [String: Any] {
        guard isOn(services) else { throw failure(CloudFolderAddStrings.off) }
        guard let target = CloudUploads.target(tab: tab, services: services), target.session == session else {
            throw failure(CloudFolderAddStrings.unavailable)
        }
        guard let folder = await NewTabPage.chooseFolder(in: NSApp.keyWindow) else { return ["applied": "cancelled"] }
        let started = ContinuousClock.now
        guard let socket = await target.machine.daemon.connection?.endpoint?.socketPath else { throw failure(CloudFolderAddStrings.unavailable) }
        let answer: CloudAccessCLI.Answer
        do {
            answer = try await CloudAccessCLI(binary: target.binary).grantAttached(
                socket: socket, machine: target.machine.machineID, session: session, remoteRoot: target.remoteRoot, folder: folder.path)
        } catch {
            answer = CloudAccessCLI.Answer(ok: false, error: String(describing: error))
        }
        let logger = services.cloud.logger
        guard answer.ok, let path = answer.attachedPath else {
            logger.error("cloud folder add: session \(session, privacy: .public) failed \(answer.errorCode ?? "", privacy: .public)")
            // The CLI's reason names what was refused and why ("… cannot be shared: credential folders are never shared").
            throw failure(answer.error ?? CloudFolderAddStrings.failed)
        }
        let applied = answer.attachedApplied ?? "now"
        let took = started.duration(to: .now).components
        let ms = Int(took.seconds) * 1000 + Int(took.attoseconds / 1_000_000_000_000_000)
        logger.info("cloud folder add: session \(session, privacy: .public) applied \(applied, privacy: .public) in \(ms) ms")
        return ["applied": applied, "path": path, "from": folder.path]
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "cloud.folder.add", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Add Folder's failure texts, shown in the chat.
enum CloudFolderAddStrings {
    static var off: String {
        String(localized: "cloud.folderAdd.off", defaultValue: "Adding folders to Cloud chats is turned off in Settings.", table: "Cloud", bundle: .module.inAppLanguage)
    }
    static var unavailable: String {
        String(localized: "cloud.folderAdd.unavailable", defaultValue: "This chat's Cloud machine isn't connected.", table: "Cloud", bundle: .module.inAppLanguage)
    }
    static var failed: String {
        String(localized: "cloud.folderAdd.failed", defaultValue: "The folder couldn't be added.", table: "Cloud", bundle: .module.inAppLanguage)
    }
}
