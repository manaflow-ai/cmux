import CmuxCloudResizeCore
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

    /// Parse a Freestyle memory allocation expressed in whole GiB.
    static func parseCloudVMMemoryMb(_ raw: String) -> Int? {
        guard let gib = parseCloudVMGiB(raw), (4...64).contains(gib) else { return nil }
        return gib * 1024
    }

    /// Builds the typed resize limits from the server's list response.
    private static func cloudVMResizeLimits(from limits: [String: Any]) throws -> (CloudVMResizeLimits, planID: String) {
        let plan: CloudVMResizePlan
        do {
            plan = try CloudVMResizePlanValidator().plan(from: limits)
        } catch CloudVMResizePlanError.incompleteCapacityData {
            throw CLIError(message: String(
                localized: "cli.vm.resize.preflightIncomplete",
                defaultValue: "vm resize: the server returned incomplete plan capacity data; retry after refreshing your Cloud machines."
            ))
        }
        return (plan.limits, planID: plan.id)
    }

    /// Parses a strictly positive resize dimension without trapping on oversized JSON numbers.
    private static func cloudVMResizePositiveLimit(_ raw: Any?) -> Int? {
        CloudVMResizePlanValidator().positiveLimit(raw)
    }

    /// Validates plan ceilings for callers that only have a target shape.
    static func validateCloudVMResizePlan(
        diskMb: Int?,
        cpu: Int?,
        memoryMb: Int?,
        limits: [String: Any]
    ) throws {
        let (resizeLimits, planID) = try cloudVMResizeLimits(from: limits)
        let target = CloudVMResizeShape(vcpus: cpu, memoryMb: memoryMb, diskMb: diskMb)
        if let failure = CloudVMResizePlanValidator().violation(
            target: target,
            current: nil,
            usesResourcePool: false,
            limits: resizeLimits
        ) {
            throw cloudVMResizeFailureError(failure, planID: planID)
        }
    }

    /// Converts a typed resize violation into the localized CLI error shown to the user.
    private static func cloudVMResizeFailureError(
        _ failure: CloudVMResizeViolation,
        planID: String
    ) -> CLIError {
        switch failure {
        case .planLimit(let resource, let requested, let maximum):
            return cloudVMResizePlanError(planID: planID, resource: resource, requested: requested, maximum: maximum)
        case .notLarger(let resource, _, let current):
            let resourceName = cloudVMResizeResourceLabel(resource)
            return CLIError(message: String(
                format: String(
                    localized: "cli.vm.resize.notLarger",
                    defaultValue: "vm resize: %@ is already %@; choose a larger size."
                ),
                resourceName,
                cloudVMResizeValue(resource, requested: current)
            ))
        case .missingCurrentShape:
            return CLIError(message: String(
                localized: "cli.vm.resize.preflightIncomplete",
                defaultValue: "vm resize: the server returned incomplete machine capacity data; retry after refreshing your Cloud machines."
            ))
        case .poolLimit(let requestedVcpus, let requestedMemoryMb, let freeVcpus, let freeMemoryMb):
            return cloudVMResizePoolError(
                requestedCPUs: requestedVcpus,
                requestedMemoryMb: requestedMemoryMb,
                freeCPUs: freeVcpus,
                freeMemoryMb: freeMemoryMb
            )
        }
    }

    /// Returns the localized label for one resize dimension.
    private static func cloudVMResizeResourceLabel(_ resource: CloudVMResizeViolation.Resource) -> String {
        switch resource {
        case .disk:
            return String(localized: "cli.vm.resize.resource.disk", defaultValue: "disk")
        case .vcpus:
            return String(localized: "cli.vm.resize.resource.cpu", defaultValue: "CPU")
        case .memory:
            return String(localized: "cli.vm.resize.resource.memory", defaultValue: "memory")
        }
    }

    /// Formats a resize dimension in the units used by the CLI.
    private static func cloudVMResizeValue(
        _ resource: CloudVMResizeViolation.Resource,
        requested: Int
    ) -> String {
        resource == .vcpus ? "\(requested) vCPUs" : "\(requested / 1024) GiB"
    }

    /// Builds the localized error for a target above its plan ceiling.
    private static func cloudVMResizePlanError(
        planID: String,
        resource: CloudVMResizeViolation.Resource,
        requested: Int,
        maximum: Int
    ) -> CLIError {
        let requestedText = cloudVMResizeValue(resource, requested: requested)
        let maximumText = cloudVMResizeValue(resource, requested: maximum)
        let resourceName = cloudVMResizeResourceLabel(resource)
        let planName = cloudVMResizePlanName(planID)
        let upgrade: String
        if planID.lowercased() == "max" {
            upgrade = String(localized: "cli.vm.resize.chooseSmaller", defaultValue: "Choose a smaller size.")
        } else if planID.lowercased() == "go" &&
                    ((resource == .memory && requested <= 16 * 1_024) ||
                     (resource == .vcpus && requested <= 8) ||
                     (resource == .disk && requested <= 128 * 1_024)) {
            upgrade = String(localized: "cli.vm.resize.upgradePro", defaultValue: "Upgrade to cmux Pro to use this size.")
        } else {
            upgrade = String(localized: "cli.vm.resize.upgradeMax", defaultValue: "Upgrade to cmux Max to use larger sizes.")
        }
        let message = String(
            format: String(
                localized: "cli.vm.resize.planLimit",
                defaultValue: "vm resize: the %@ plan cannot resize %@ to %@; its maximum is %@. %@"
            ),
            planName, resourceName, requestedText, maximumText, upgrade
        )
        return CLIError(message: message)
    }

    /// Returns the localized display name for a normalized plan identifier.
    private static func cloudVMResizePlanName(_ planID: String) -> String {
        let localizedName: String
        switch planID.lowercased() {
        case "pro": localizedName = String(localized: "pricing.native.plan.pro", defaultValue: "Pro")
        case "max": localizedName = String(localized: "pricing.native.plan.max", defaultValue: "Max")
        case "team": localizedName = String(localized: "pricing.native.plan.team", defaultValue: "Team")
        case "founders", "founders-edition": localizedName = String(localized: "cli.vm.resize.planName.founders", defaultValue: "Founder's Edition")
        case "go": localizedName = String(localized: "pricing.native.plan.go", defaultValue: "Go")
        case "free": localizedName = String(localized: "pricing.native.plan.free", defaultValue: "Free")
        default: return planID
        }
        return "cmux \(localizedName)"
    }

    /// Builds the localized error for a target above the shared compute pool.
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

    /// Parses a whole-number GiB value with an optional provider suffix.
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
        let listResponse: [String: Any]
        do {
            listResponse = try client.sendV2(method: "vm.list", responseTimeout: 60)
        } catch {
            throw CLIError(message: String(
                localized: "cli.vm.resize.listFailed",
                defaultValue: "vm resize: could not refresh plan limits before resizing; no changes were made."
            ))
        }
        guard let limits = listResponse["limits"] as? [String: Any] else {
            throw CLIError(message: String(
                localized: "cli.vm.resize.preflightIncomplete",
                defaultValue: "vm resize: the server returned incomplete plan capacity data; retry after refreshing your Cloud machines."
            ))
        }
        let machines = (listResponse["vms"] as? [[String: Any]])
            ?? (listResponse["machines"] as? [[String: Any]])
            ?? []
        // `vm resize` accepts either the provider id or the user-facing slug.
        // Always forward the canonical id to the mutation when the list found
        // a slug match; the server's resize endpoint is keyed by id.
        let machine = machines.first {
            ($0["id"] as? String) == vmId || ($0["slug"] as? String) == vmId
        }
        let machineID = (machine?["id"] as? String) ?? vmId
        let (resizeLimits, planID) = try Self.cloudVMResizeLimits(from: limits)
        let status = (machine?["status"] as? String)?.lowercased()
        let reservation = machine?["resourceReservation"] as? [String: Any]
        let poolClaim = machine?["resources"] as? [String: Any]
        let current = CloudVMResizeShape(
            vcpus: Self.cloudVMResizePositiveLimit(reservation?["vcpus"])
                ?? Self.cloudVMResizePositiveLimit(machine?["cpus"]),
            memoryMb: Self.cloudVMResizePositiveLimit(reservation?["memoryMb"])
                ?? Self.cloudVMResizePositiveLimit(machine?["memory_total_mb"])
                ?? Self.cloudVMResizePositiveLimit(machine?["memoryTotalMb"]),
            diskMb: Self.cloudVMResizePositiveLimit(reservation?["diskMb"])
                ?? Self.cloudVMResizePositiveLimit(machine?["disk_total_mb"])
                ?? Self.cloudVMResizePositiveLimit(machine?["diskTotalMb"])
        )
        let poolClaimShape: CloudVMResizeShape?
        if let poolClaim {
            guard let claimVcpus = Self.cloudVMResizePositiveLimit(poolClaim["vcpus"]),
                  let claimMemoryMb = Self.cloudVMResizePositiveLimit(poolClaim["memoryMb"]) else {
                throw CLIError(message: String(
                    localized: "cli.vm.resize.preflightIncomplete",
                    defaultValue: "vm resize: the server returned incomplete machine capacity data; retry after refreshing your Cloud machines."
                ))
            }
            poolClaimShape = CloudVMResizeShape(
                vcpus: claimVcpus,
                memoryMb: claimMemoryMb,
                diskMb: Self.cloudVMResizePositiveLimit(poolClaim["diskMb"])
            )
        } else {
            poolClaimShape = nil
        }
        let target = CloudVMResizeShape(vcpus: cpu, memoryMb: memoryMb, diskMb: diskMb)
        if let failure = CloudVMResizePlanValidator().violation(
            target: target,
            current: current,
            usesResourcePool: status == "running" || status == "provisioning",
            reservation: poolClaimShape,
            limits: resizeLimits
        ) {
            throw Self.cloudVMResizeFailureError(failure, planID: planID)
        }
        var params: [String: Any] = ["id": machineID]
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

        Create a Cloud VM. Pro supports sizes through 16g; 24g, 32g, and 64g require Max.
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
