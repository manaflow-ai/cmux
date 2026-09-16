import Foundation

// MARK: - `cmux vm <verb> --help`

extension CMUXCLI {
    /// Usage for the verbs that carry their own option list. `cmux vm <verb> --help`
    /// and `-h` print this instead of the `cmux vm` overview, without a socket, so an
    /// agent can read a verb's flags before the app is running. Verbs not listed here
    /// are documented in full by the overview and fall back to it.
    static func vmSubcommandUsage(_ args: [String]) -> String? {
        guard let verb = args.first?.lowercased() else { return nil }
        switch verb {
        case "resize": return vmResizeUsage
        case "run": return vmRunUsage
        case "route": return vmRouteUsage
        case "agent": return vmAgentUsage
        case "push", "upload": return vmPushUsage
        case "pull", "download": return vmPullUsage
        case "wait": return vmWaitUsage
        case "open", "port": return vmOpenUsage
        case "tree": return vmTreeUsage
        case "workspace": return vmWorkspaceUsage
        case "terminal": return vmTerminalUsage
        case "tui": return vmTuiUsage
        case "prompt", "skill": return vmPromptUsage
        case "base": return vmBaseUsage
        case "domains": return cloudDomainsUsage
        default: return nil
        }
    }

    /// Parse a Freestyle grow-only disk allocation expressed in GiB.
    ///
    /// - Parameter raw: A whole-number size with an optional `G`, `GB`, or `GiB` suffix.
    /// - Returns: The validated size in MiB, or `nil` when it is outside the provider contract.
    static func parseCloudVMDiskMb(_ raw: String) -> Int? {
        guard let gib = parseCloudVMGiB(raw), (4...256).contains(gib), gib % 4 == 0 else { return nil }
        return gib * 1024
    }

    static func parseCloudVMMemoryMb(_ raw: String) -> Int? {
        guard let gib = parseCloudVMGiB(raw), (4...64).contains(gib) else { return nil }
        return gib * 1024
    }

    private static func parseCloudVMGiB(_ raw: String) -> Int? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let number = normalized.hasSuffix("gib") ? String(normalized.dropLast(3))
            : normalized.hasSuffix("gb") ? String(normalized.dropLast(2))
            : normalized.hasSuffix("g") ? String(normalized.dropLast())
            : normalized
        return Int(number)
    }

    static var vmResizeUsage: String {
        String(localized: "cli.vm.resize.usage", defaultValue: """
        Usage:
          cmux vm resize <id> [--cpu <vCPUs>] [--memory <GiB>] [--disk <GiB>]

        Grow an existing Cloud VM in place. Specify at least one resource:
        CPU: 1–32 vCPUs. Memory: 4–64 GiB in whole GiB. Disk: 4–256 GiB in 4 GiB steps.
        Memory and disk accept G, GB, or GiB suffixes. Shrinking is not supported.
        The server enforces plan limits and returns the provider-confirmed resources.
        Add --json for the structured result.
        """)
    }

    /// Execute the CLI's one-machine resource resize contract after validating every argument.
    func runVMResizeCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        if rest.contains("--help") || rest.contains("-h") {
            print(Self.vmResizeUsage)
            return
        }
        let (diskOpt, r1) = parseOption(rest, name: "--disk")
        let (cpuOpt, r2) = parseOption(r1, name: "--cpu")
        let (memoryOpt, remaining) = parseOption(r2, name: "--memory")
        guard remaining.count == 1, let vmId = remaining.first,
              !vmId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !vmId.hasPrefix("-"), diskOpt != nil || cpuOpt != nil || memoryOpt != nil else {
            throw CLIError(message: Self.vmResizeUsage)
        }
        let diskMb = diskOpt.flatMap(Self.parseCloudVMDiskMb)
        let cpu = cpuOpt.flatMap(Int.init).flatMap { (1...32).contains($0) ? $0 : nil }
        let memoryMb = memoryOpt.flatMap(Self.parseCloudVMMemoryMb)
        if (diskOpt != nil && diskMb == nil) || (cpuOpt != nil && cpu == nil) || (memoryOpt != nil && memoryMb == nil) {
            throw CLIError(message: String(
                localized: "cli.vm.resize.invalidDisk",
                defaultValue: "vm resize: use CPU 1–32, memory 4–64 GiB in whole GiB, and disk 4–256 GiB in 4 GiB steps."
            ))
        }
        var params: [String: Any] = ["id": vmId]
        if let diskMb { params["storage_mb"] = diskMb }
        if let cpu { params["cpu"] = cpu }
        if let memoryMb { params["memory_mb"] = memoryMb }
        let response = try client.sendV2(
            method: "vm.resize",
            params: params,
            responseTimeout: 120
        )
        if jsonOutput {
            print(jsonString(response))
            return
        }
        let disk = (response["disk_total_mb"] as? Int) ?? (response["diskTotalMb"] as? Int)
        let memory = (response["memory_total_mb"] as? Int) ?? (response["memoryTotalMb"] as? Int)
        let cpus = (response["cpus"] as? Int)
        let format = String(localized: "cli.vm.resize.success", defaultValue: "OK %@ cpu=%@ memory=%@ GiB disk=%@ GiB")
        print(String(format: format, vmId, cpus.map(String.init) ?? "-", memory.map { String($0 / 1024) } ?? "-", disk.map { String($0 / 1024) } ?? "-"))
    }

    static var vmPromptUsage: String {
        """
        Usage:
          cmux vm prompt [--json]          Install the cmux-cloud skill file and print
                                           the kickoff prompt that points any agent at it.
          cmux vm prompt --open <agent>    Open a local terminal running <agent> with that
                                           prompt (claude|codex|opencode).
        """
    }

    static var vmBaseUsage: String {
        """
        Usage:
          cmux vm base open [--desktop|--base] [--workspace <workspace-id>] [--window <id|ref|index>] [--focus <true|false>] [--detach|-d]
          cmux vm base reset [--desktop|--base] [--reason <text>] [--workspace <workspace-id>] [--window <id|ref|index>] [--detach|-d]

        Base is your persistent cloud workspace. Opening it reuses the
        same VM. Reset creates a new Base generation and retains the old VM.
        """
    }
}
