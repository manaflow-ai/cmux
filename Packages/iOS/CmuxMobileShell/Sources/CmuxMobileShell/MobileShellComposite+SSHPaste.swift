internal import CMUXMobileCore
internal import CmuxMobileSSH
import Foundation

/// Image paste into an SSH terminal (PRD D21). A paired Mac receives the
/// bytes over `terminal.paste_image` and types a temp-file path; an SSH host
/// has no cmux service, so the phone uploads the image itself over SFTP to
/// `~/.cmux/uploads/` and types the shell-quoted remote path, which is what
/// TUIs such as Claude Code pick up as an attached image.
@MainActor
extension MobileShellComposite {
    static let sshUploadsDirectoryCommand = "mkdir -p ~/.cmux/uploads && cd ~/.cmux/uploads && pwd"

    func submitSSHTerminalPasteImage(_ data: Data, format: String, surfaceID: String) async -> Bool {
        guard let hostID = sshComputers.hostID(forIdentifier: surfaceID) else { return false }
        do {
            let result = try await sshComputers.exec(hostID: hostID, Self.sshUploadsDirectoryCommand)
            let directory = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.exitStatus == 0, directory.hasPrefix("/") else {
                throw SFTPError.failure(result.stdoutString)
            }
            let remotePath = directory + "/" + Self.sshPasteImageFileName(format: format, date: Date())
            let sftp = try await sshComputers.openSFTP(hostID: hostID)
            do {
                try await sftp.writeFile(remotePath, data: data)
            } catch {
                await sftp.close()
                throw error
            }
            await sftp.close()
            sshComputers.input(Data(remotePath.remotePathShellWord.utf8), surfaceID: surfaceID)
            recordAppEvent(.terminalImagePasteSucceeded, correlationID: surfaceID, count: data.count)
            return true
        } catch {
            recordAppEvent(
                .terminalImagePasteFailed,
                correlationID: surfaceID,
                failure: error as? SFTPError == .permissionDenied ? .permissionDenied : .connectionClosed,
                count: data.count
            )
            return false
        }
    }

    /// `<yyyyMMdd-HHmmss-SSS>.<ext>` with the extension restricted to a
    /// short alphanumeric token (`png` otherwise), mirroring the Mac's
    /// format sanitizing.
    nonisolated static func sshPasteImageFileName(format: String, date: Date) -> String {
        let lowered = format.lowercased()
        let ext = !lowered.isEmpty && lowered.count <= 5 && lowered.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
            ? lowered : "png"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "\(formatter.string(from: date)).\(ext)"
    }
}
