import Darwin
import Foundation

extension CMUXCLI {
    func tmuxEnrichContextWithProcessFormats(_ context: inout [String: String], surface: [String: Any]) {
        let paneStartCommand = [
            surface["tmux_start_command"],
            surface["pane_start_command"],
            surface["initial_command"]
        ]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        if let paneStartCommand {
            context["pane_start_command"] = paneStartCommand
            if let currentCommand = tmuxCurrentCommandName(from: paneStartCommand) {
                context["pane_current_command"] = currentCommand
            }
        }
        tmuxEnrichContextWithProcessInfo(&context, surface: surface)
    }

    /// Reads the selected PTY's live processes in the CLI, away from the app's main thread.
    func tmuxEnrichContextWithProcessInfo(_ context: inout [String: String], surface: [String: Any]) {
        guard let tty = surface["tty"] as? String, tty.hasPrefix("/dev/") else { return }
        context["pane_tty"] = tty
        guard let foregroundPID = intFromAny(surface["foreground_pid"]),
              let foreground = tmuxProcessInfo(pid: foregroundPID) else { return }

        var device = stat()
        guard stat(tty, &device) == 0,
              foreground.e_tdev == UInt32(bitPattern: device.st_rdev) else { return }

        // tmux's pane_pid is the initial process, not the foreground job. Walk
        // only this PTY's ancestry so a nested shell or pipeline cannot change it.
        var root = foreground
        var visited = Set<UInt32>()
        while visited.insert(root.pbi_pid).inserted,
              visited.count < 128,
              root.pbi_ppid > 1,
              let parent = tmuxProcessInfo(pid: Int(root.pbi_ppid)),
              parent.e_tdev == foreground.e_tdev {
            root = parent
        }
        context["pane_pid"] = String(root.pbi_pid)
        context["pane_dead"] = "0"

        var name = [CChar](repeating: 0, count: 1024)
        let length = proc_name(Int32(foregroundPID), &name, UInt32(name.count))
        if length > 0 {
            let command = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !command.isEmpty {
                context["pane_current_command"] = (command as NSString).lastPathComponent
            }
        }
    }

    private func tmuxProcessInfo(pid: Int) -> proc_bsdinfo? {
        guard let pid = Int32(exactly: pid), pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(pid) else { return nil }
        return info
    }
}
