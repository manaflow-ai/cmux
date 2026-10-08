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
        case "new", "create": return vmNewUsage
        case "ls", "list": return vmListUsage
        case "ports": return vmPortsUsage
        case "resize": return vmResizeUsage
        case "network": return vmNetworkUsage
        case "agent-updates": return vmAgentUpdatesUsage
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

    /// The list response carries the caller's plan ceilings. Validate them
    /// before sending a provider mutation so the CLI has the same affordance
    /// gate as the sidebar. The backend repeats these checks transactionally.
    static func validateCloudVMResizePlan(
        diskMb: Int?,
        cpu: Int?,
        memoryMb: Int?,
        limits: [String: Any]
    ) throws {
        // Older app/control-plane pairs may omit the limits object entirely.
        // Keep the client-side gate conservative in that case instead of
        // accidentally allowing a Max-only request through to the provider.
        let planID = (limits["planId"] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "pro"
        let maxMemoryFromLadder = (limits["memoryOptionsMb"] as? [Any])?.compactMap(positiveCloudVMLimit).max()
        let maxMemoryMb = positiveCloudVMLimit(limits["maxMemoryMb"])
            ?? maxMemoryFromLadder
            ?? (planID == "max" ? 64 * 1_024 : planID == "go" ? 4 * 1_024 : 32 * 1_024)
        let maxVcpus = positiveCloudVMLimit(limits["maxVcpus"])
            // The vcpusByMemoryMb map also contains locked Max rows, so its
            // largest value is not a safe fallback for a Pro response. The
            // server derives this ceiling from the accepted memory ceiling.
            ?? max(1, maxMemoryMb / 2_048)
        let maxDiskMb = positiveCloudVMLimit(limits["maxDiskMb"]) ?? {
            switch planID.lowercased() {
            case "max": return 256 * 1_024
            case "go": return 16 * 1_024
            default: return 128 * 1_024
            }
        }()
        if let diskMb, diskMb > maxDiskMb {
            throw cloudVMResizePlanError(planID: planID, resource: "disk", requested: diskMb, maximum: maxDiskMb)
        }
        if let cpu, cpu > maxVcpus {
            throw cloudVMResizePlanError(planID: planID, resource: "CPU", requested: cpu, maximum: maxVcpus)
        }
        if let memoryMb, memoryMb > maxMemoryMb {
            throw cloudVMResizePlanError(planID: planID, resource: "memory", requested: memoryMb, maximum: maxMemoryMb)
        }
    }

    private static func positiveCloudVMLimit(_ raw: Any?) -> Int? {
        if let value = raw as? Int, value > 0 { return value }
        if let number = raw as? NSNumber,
           number.doubleValue.isFinite,
           number.doubleValue == Double(number.intValue),
           number.intValue > 0 { return number.intValue }
        if let value = raw as? Double,
           value.isFinite,
           value > 0,
           value == value.rounded() { return Int(value) }
        return nil
    }

    private static func cloudVMResizePlanError(
        planID: String,
        resource: String,
        requested: Int,
        maximum: Int
    ) -> CLIError {
        let requestedText = resource == "CPU" ? "\(requested) vCPUs" : "\(requested / 1024) GiB"
        let maximumText = resource == "CPU" ? "\(maximum) vCPUs" : "\(maximum / 1024) GiB"
        let planName: String
        switch planID.lowercased() {
        case "pro": planName = "cmux Pro"
        case "max": planName = "cmux Max"
        case "team": planName = "cmux Team"
        case "founders", "founders-edition": planName = "cmux Founder's Edition"
        case "go": planName = "cmux Go"
        case "free": planName = "cmux Free"
        default: planName = planID
        }
        let upgrade: String
        if planID.lowercased() == "max" {
            upgrade = String(localized: "cli.vm.resize.chooseSmaller", defaultValue: "Choose a smaller size.")
        } else if planID.lowercased() == "go" &&
                    ((resource == "memory" && requested <= 32 * 1_024) ||
                     (resource == "CPU" && requested <= 16) ||
                     (resource == "disk" && requested <= 128 * 1_024)) {
            upgrade = String(localized: "cli.vm.resize.upgradePro", defaultValue: "Upgrade to cmux Pro to use this size.")
        } else {
            upgrade = String(localized: "cli.vm.resize.upgradeMax", defaultValue: "Upgrade to cmux Max to use larger sizes.")
        }
        let message = String(
            format: String(
                localized: "cli.vm.resize.planLimit",
                defaultValue: "vm resize: the %@ plan cannot resize %@ to %@; its maximum is %@. %@"
            ),
            planName, resource, requestedText, maximumText, upgrade
        )
        return CLIError(message: message)
    }

    private static func cloudVMResizePoolError(
        requestedCPUs: Int,
        requestedMemoryMb: Int,
        freeCPUs: Int,
        freeMemoryMb: Int
    ) -> CLIError {
        let message = String(
            format: String(
                localized: "cli.vm.resize.poolLimit",
                defaultValue: "vm resize: this target needs %lld vCPUs and %lld GiB RAM, but only %lld vCPUs and %lld GiB are free in your plan pool. Pause or delete a VM, or choose a smaller size."
            ),
            Int64(requestedCPUs), Int64(requestedMemoryMb / 1_024),
            Int64(freeCPUs), Int64(freeMemoryMb / 1_024)
        )
        return CLIError(message: message)
    }

    /// Checks the complete target shape against the server-published shared
    /// pool. Active VMs already contribute their reservation to `used*`; a
    /// paused VM is treated as a new allocation because resize wakes it.
    private static func validateCloudVMResizePool(
        diskMb: Int?,
        cpu: Int?,
        memoryMb: Int?,
        limits: [String: Any],
        machine: [String: Any]?
    ) throws {
        guard let poolCPUs = positiveCloudVMLimit(limits["poolVcpus"]),
              let poolMemoryMb = positiveCloudVMLimit(limits["poolMemoryMb"]) else { return }
        let usedCPUs = positiveCloudVMLimit(limits["usedVcpus"]) ?? 0
        let usedMemoryMb = positiveCloudVMLimit(limits["usedMemoryMb"]) ?? 0
        let status = (machine?["status"] as? String)?.lowercased()
        let active = status == "running" || status == "provisioning"
        let resources = machine?["resources"] as? [String: Any]
        let currentCPUs = positiveCloudVMLimit(resources?["vcpus"])
            ?? positiveCloudVMLimit(machine?["cpus"])
        let currentMemoryMb = positiveCloudVMLimit(resources?["memoryMb"])
            ?? positiveCloudVMLimit(machine?["memory_total_mb"])
            ?? positiveCloudVMLimit(machine?["memoryTotalMb"])

        // A running disk-only resize does not wake or grow compute. Every
        // other resize needs the complete target shape to be known.
        if diskMb != nil && cpu == nil && memoryMb == nil && active { return }
        guard let currentCPUs, let currentMemoryMb,
              let targetCPUs = cpu ?? currentCPUs,
              let targetMemoryMb = memoryMb ?? currentMemoryMb else {
            throw cloudVMResizePoolError(
                requestedCPUs: cpu ?? 0,
                requestedMemoryMb: memoryMb ?? 0,
                freeCPUs: 0,
                freeMemoryMb: 0
            )
        }

        let otherCPUs = active ? max(0, usedCPUs - currentCPUs) : usedCPUs
        let otherMemoryMb = active ? max(0, usedMemoryMb - currentMemoryMb) : usedMemoryMb
        let freeCPUs = max(0, poolCPUs - otherCPUs)
        let freeMemoryMb = max(0, poolMemoryMb - otherMemoryMb)
        guard targetCPUs <= freeCPUs, targetMemoryMb <= freeMemoryMb else {
            throw cloudVMResizePoolError(
                requestedCPUs: targetCPUs,
                requestedMemoryMb: targetMemoryMb,
                freeCPUs: freeCPUs,
                freeMemoryMb: freeMemoryMb
            )
        }
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
        The CLI checks your plan's limits before the request; the server enforces them again
        and returns the provider-confirmed resources.
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
        let listResponse = try client.sendV2(method: "vm.list", responseTimeout: 60)
        let limits = (listResponse["limits"] as? [String: Any]) ?? [:]
        try Self.validateCloudVMResizePlan(
            diskMb: diskMb,
            cpu: cpu,
            memoryMb: memoryMb,
            limits: limits
        )
        let machines = (listResponse["vms"] as? [[String: Any]])
            ?? (listResponse["machines"] as? [[String: Any]])
            ?? []
        let machine = machines.first { ($0["id"] as? String) == vmId }
        try Self.validateCloudVMResizePool(
            diskMb: diskMb,
            cpu: cpu,
            memoryMb: memoryMb,
            limits: limits,
            machine: machine
        )
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
                                           prompt (claude|codex|opencode|pi).
        """
    }

    static var vmNewUsage: String {
        String(localized: "cli.vm.new.usage", defaultValue: """
        Usage:
          cmux vm new [--size <4g|8g|16g|24g|32g|64g>] [--agent-updates <latest|image>]
                      [--name <label>] [--provider <provider>] [--image <image-id>]
                      [--workspace <workspace-id>] [--network <full|allowlist|none>]
                      [--focus|--no-focus] [--detach|-d]

        Create a Cloud VM. Pro supports sizes through 32g; 64g requires Max.
        The server enforces plan limits and shared CPU and memory pools.
        `--detach` creates the machine without opening its workspace.
        """)
    }

    static var vmListUsage: String {
        String(localized: "cli.vm.list.usage", defaultValue: """
        Usage:
          cmux vm ls [--json]
          cmux vm list [--json]

        List your Cloud VMs, their state, provider, image, and plan usage.
        """)
    }

    static var vmPortsUsage: String {
        String(localized: "cli.vm.ports.usage", defaultValue: """
        Usage:
          cmux vm ports <machine> [--json]

        Show listening TCP ports inside a Cloud VM.
        """)
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
