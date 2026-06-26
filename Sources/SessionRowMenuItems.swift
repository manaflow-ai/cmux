import AppKit
import SwiftUI

/// Right-click menu items for any session row (full or popover). A `View` so
/// `SessionRow` and `PopoverRow` both attach the same set without duplicating
/// the button list or the action helpers.
struct SessionRowMenuItems: View {
    let entry: SessionEntry
    let onResume: ((SessionEntry) -> Void)?

    var body: some View {
        if let onResume {
            Button {
                onResume(entry)
            } label: {
                Text(String(localized: "sessionIndex.row.resume", defaultValue: "Resume in New Tab"))
            }
            Divider()
        }
        if let url = entry.fileURL {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Text(String(localized: "sessionIndex.row.open", defaultValue: "Open"))
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Text(String(localized: "sessionIndex.row.reveal", defaultValue: "Reveal in Finder"))
            }
            Divider()
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(url.path, forType: .string)
            } label: {
                Text(String(localized: "sessionIndex.row.copyPath", defaultValue: "Copy File Path"))
            }
        }
        if let resumeCommand = entry.resumeCommand {
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(resumeCommand, forType: .string)
            } label: {
                Text(String(localized: "sessionIndex.row.copyResume", defaultValue: "Copy Resume Command"))
            }
        }
        if let cwd = entry.cwd, !cwd.isEmpty {
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
            } label: {
                Text(String(localized: "sessionIndex.row.openCwd", defaultValue: "Open Working Directory"))
            }
        }
        if let pr = entry.pullRequest, let url = URL(string: pr.url) {
            Divider()
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Text(String(localized: "sessionIndex.row.openPR", defaultValue: "Open Pull Request"))
            }
        }
    }
}
