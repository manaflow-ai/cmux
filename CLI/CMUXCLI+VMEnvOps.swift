import Foundation

/// `cmux vm env` subcommands that ride on cached layers: `up` (restore the
/// fully cached environment and attach), `init` (scaffold .cmux/env.yaml),
/// `layers` (list cached layers), and `logs` (tail step logs inside a VM).
extension CMUXCLI {
    // MARK: - up

    func runVMEnvUp(
        args: [String],
        client: SocketClient,
        jsonOutput: Bool,
        windowId: String?,
        idFormat: CLIIDFormat
    ) throws {
        let (loaded, afterSpec) = try vmEnvLoadSpec(args: args)
        let (windowOpt, afterWindow) = parseOption(afterSpec, name: "--window")
        let detach = hasFlag(afterWindow, name: "--detach") || hasFlag(afterWindow, name: "-d")
        let spec = loaded.spec

        let resolveEmpty = try client.sendV2(
            method: "vm.env_resolve_layers",
            params: ["chain_hashes": [String]()],
            responseTimeout: 60
        )
        guard let provider = resolveEmpty["provider"] as? String,
              let defaultBaseImage = resolveEmpty["base_image_id"] as? String else {
            throw CLIError(message: "vm env up: backend did not return a provider/base image.")
        }
        let baseImageId = (spec.base?.isEmpty == false && spec.base?.lowercased() != "default") ? spec.base! : defaultBaseImage
        let chainHashes = VMEnvSpecCodec.chainHashes(provider: provider, baseImageId: baseImageId, spec: spec)
        let resolve = try client.sendV2(
            method: "vm.env_resolve_layers",
            params: ["provider": provider, "chain_hashes": chainHashes],
            responseTimeout: 60
        )
        guard let layer = resolve["layer"] as? [String: Any],
              let stepIndex = layer["step_index"] as? Int,
              let snapshotId = layer["snapshot_id"] as? String,
              stepIndex == spec.steps.count - 1 else {
            throw CLIError(message: """
                This spec is not fully cached yet (or changed since the last build).

                Run:
                  cmux vm env build
                """)
        }
        // The final layer is registered (with the spec digest of that build)
        // only after verify passes, so a digest mismatch means this exact spec
        // text has never had a passing build. `build` on a fully cached spec
        // just re-runs verify and refreshes the digest.
        guard (layer["spec_digest"] as? String) == loaded.digest else {
            throw CLIError(message: """
                The spec changed since its last passing build (steps may be cached, but `verify` has not passed for this exact spec text).

                Run:
                  cmux vm env build
                """)
        }

        let response = try client.sendV2(
            method: "vm.restore",
            params: [
                "snapshot_id": snapshotId,
                "provider": provider,
                "idempotency_key": UUID().uuidString.lowercased(),
            ],
            responseTimeout: Self.vmEnvLongOpTimeout
        )
        guard let vmId = response["id"] as? String, !vmId.isEmpty else {
            throw CLIError(message: "vm env up: restore returned no VM id")
        }
        if jsonOutput {
            print(jsonString(["ok": true, "vmId": vmId, "snapshotId": snapshotId, "provider": provider]))
            return
        }
        print("Restored environment into VM \(vmId)")
        if detach {
            print("Attach: cmux vm shell \(vmId)")
            return
        }
        let workspaceName = spec.name.map { "env:\($0)" } ?? "env:\(String(vmId.prefix(8)))"
        try vmOpenShell(
            id: vmId,
            workspaceName: workspaceName,
            windowRaw: windowOpt ?? windowId,
            forceSSH: false,
            shouldPinWorkspaceToTop: false,
            client: client,
            jsonOutput: jsonOutput,
            idFormat: idFormat
        )
    }

    // MARK: - init

    func runVMEnvInit(args: [String], jsonOutput: Bool) throws {
        let (goalOpt, _) = parseOption(args, name: "--goal")
        let path = ".cmux/env.yaml"
        if FileManager.default.fileExists(atPath: path) {
            throw CLIError(message: "\(path) already exists. Edit it, then run `cmux vm env build`.")
        }
        try FileManager.default.createDirectory(atPath: ".cmux", withIntermediateDirectories: true)
        let goalComment = goalOpt.map { "# Goal: \($0)\n" } ?? ""
        let template = """
        \(goalComment)# cmux Cloud VM environment spec. Each step becomes a cached snapshot layer:
        # edit a step and only that layer (and later ones) re-run on the next build.
        version: 1
        name: my-project
        steps:
          - name: system packages
            run: sudo apt-get update && sudo apt-get install -y build-essential
          - name: clone
            run: |
              git clone https://github.com/OWNER/REPO
        verify:
          - run: test -d REPO
        """
        try (template + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        if jsonOutput {
            print(jsonString(["ok": true, "path": path]))
        } else {
            print("Wrote \(path). Edit the steps, then: cmux vm env build")
        }
    }

    // MARK: - layers

    func runVMEnvLayers(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        var params: [String: Any] = [:]
        if let found = Self.vmEnvFindSpecUpward(from: FileManager.default.currentDirectoryPath),
           let data = FileManager.default.contents(atPath: found),
           let text = String(data: data, encoding: .utf8),
           !hasFlag(args, name: "--all") {
            params["spec_digest"] = VMEnvSpecCodec.specDigest(text)
        }
        let response = try client.sendV2(method: "vm.env_list_layers", params: params, responseTimeout: 60)
        if jsonOutput {
            print(jsonString(response))
            return
        }
        let layers = (response["layers"] as? [[String: Any]]) ?? []
        if layers.isEmpty {
            print("No cached env layers. Run `cmux vm env build` (or pass --all to list every spec's layers).")
            return
        }
        for layer in layers {
            let index = (layer["step_index"] as? Int) ?? -1
            let name = (layer["step_name"] as? String) ?? "?"
            let snapshot = (layer["snapshot_id"] as? String) ?? "?"
            let hash = (layer["chain_hash"] as? String) ?? "?"
            print("layer \(index)  \(name)  snapshot=\(snapshot)  chain=\(String(hash.prefix(12)))")
        }
    }

    // MARK: - logs

    func runVMEnvLogs(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (stepOpt, remaining) = parseOption(args, name: "--step")
        guard let vmId = remaining.first else {
            throw CLIError(message: "Usage: cmux vm env logs <vm-id> [--step <n>]")
        }
        let command: String
        if let stepOpt {
            command = "tail -c 65536 \(Self.vmEnvDir)/step-\(stepOpt).log 2>/dev/null || echo 'no log for step \(stepOpt)'"
        } else {
            command = "ls -la \(Self.vmEnvDir) 2>/dev/null && for f in \(Self.vmEnvDir)/*.log; do echo \"== $f\"; tail -c 4096 \"$f\"; done"
        }
        let response = try client.sendV2(
            method: "vm.exec",
            params: ["id": vmId, "command": command, "timeout_ms": 20_000],
            responseTimeout: 40
        )
        if jsonOutput {
            print(jsonString(response))
            return
        }
        print((response["stdout"] as? String) ?? "")
    }
}
