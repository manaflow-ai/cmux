import Darwin
import Foundation

/// `cmux vm env` — declarative environment setup with layer-cached snapshots.
///
/// Each step in `.cmux/env.yaml` runs inside a Cloud VM; after a step succeeds
/// the VM is snapshotted and the snapshot registered under the step's chain
/// hash. Later builds restore the deepest cached layer (~1s on Freestyle) and
/// run only the remaining steps. Long steps run through a small runner script
/// inside the VM (started detached, polled with short execs) because a single
/// `vm.exec` cannot outlive the backend's request window.
extension CMUXCLI {
    static let vmEnvDir = "/var/tmp/cmux-env"
    static let vmEnvLongOpTimeout: TimeInterval = 16 * 60
    static let vmEnvPollIntervalSeconds: UInt32 = 2
    static let vmEnvDefaultStepTimeoutMinutes = 30

    func runVMEnvCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        windowId: String?,
        idFormat: CLIIDFormat
    ) throws {
        let sub = commandArgs.first?.lowercased() ?? "help"
        let rest = Array(commandArgs.dropFirst())
        switch sub {
        case "build":
            try runVMEnvBuild(args: rest, client: client, jsonOutput: jsonOutput)
        case "up":
            try runVMEnvUp(args: rest, client: client, jsonOutput: jsonOutput, windowId: windowId, idFormat: idFormat)
        case "init":
            try runVMEnvInit(args: rest, jsonOutput: jsonOutput)
        case "layers":
            try runVMEnvLayers(args: rest, client: client, jsonOutput: jsonOutput)
        case "logs":
            try runVMEnvLogs(args: rest, client: client, jsonOutput: jsonOutput)
        default:
            throw CLIError(message: """
                Usage: cmux vm env <build|up|init|layers|logs> [args...]

                  cmux vm env init [--goal "<text>"]     scaffold .cmux/env.yaml
                  cmux vm env build [--spec <path>] [--json] [--no-cache]
                  cmux vm env up [--spec <path>] [--window <id>] [--detach|-d]
                  cmux vm env layers [--all] [--json]
                  cmux vm env logs <vm-id> --step <n>

                A build runs each spec step in a Cloud VM, snapshots after each
                success, and caches the snapshot per step. Re-builds restore the
                deepest cached layer and only run what changed.
                """)
        }
    }

    // MARK: - Spec loading

    struct VMEnvLoadedSpec {
        let path: String
        let text: String
        let spec: VMEnvSpec
        let digest: String
    }

    func vmEnvLoadSpec(args: [String]) throws -> (spec: VMEnvLoadedSpec, remaining: [String]) {
        let (specOpt, remaining) = parseOption(args, name: "--spec")
        let path: String
        if let specOpt {
            path = (specOpt as NSString).expandingTildeInPath
        } else if let found = Self.vmEnvFindSpecUpward(from: FileManager.default.currentDirectoryPath) {
            path = found
        } else {
            throw CLIError(message: """
                No .cmux/env.yaml found here or in any parent directory.

                Create one:
                  cmux vm env init
                Or point at one:
                  cmux vm env build --spec path/to/env.yaml
                """)
        }
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "Could not read spec at \(path)")
        }
        let spec: VMEnvSpec
        do {
            spec = try VMEnvSpecCodec.parse(text)
        } catch let err as VMEnvSpecParseError {
            throw CLIError(message: "Invalid env spec at \(path)\n  \(err.description)")
        }
        return (VMEnvLoadedSpec(path: path, text: text, spec: spec, digest: VMEnvSpecCodec.specDigest(text)), remaining)
    }

    static func vmEnvFindSpecUpward(from directory: String) -> String? {
        var dir = URL(fileURLWithPath: directory)
        for _ in 0..<32 {
            let candidate = dir.appendingPathComponent(".cmux/env.yaml").path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    // MARK: - build

    private struct VMEnvStepReport {
        let index: Int
        let name: String
        var status: String
        var exitCode: Int?
        var durationMs: Int?
        var snapshotId: String?
        var chainHash: String
        var logTail: String?

        var payload: [String: Any] {
            [
                "index": index,
                "name": name,
                "status": status,
                "exitCode": exitCode ?? NSNull(),
                "durationMs": durationMs ?? NSNull(),
                "snapshotId": snapshotId ?? NSNull(),
                "chainHash": chainHash,
                "logTail": logTail ?? NSNull(),
            ]
        }
    }

    private func runVMEnvBuild(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (loaded, afterSpec) = try vmEnvLoadSpec(args: args)
        let noCache = hasFlag(afterSpec, name: "--no-cache")
        let spec = loaded.spec

        // Resolve the provider + base image the server would boot so chain
        // hashes are computed against the deployed image id.
        let resolveEmpty = try client.sendV2(
            method: "vm.env_resolve_layers",
            params: ["chain_hashes": [String]()],
            responseTimeout: 60
        )
        guard let provider = resolveEmpty["provider"] as? String,
              let defaultBaseImage = resolveEmpty["base_image_id"] as? String else {
            throw CLIError(message: "vm env build: backend did not return a provider/base image. Update the cmux app and try again.")
        }
        let baseImageId: String
        let usesCustomBase: Bool
        if let base = spec.base, !base.isEmpty, base.lowercased() != "default" {
            baseImageId = base
            usesCustomBase = true
        } else {
            baseImageId = defaultBaseImage
            usesCustomBase = false
        }

        let chainHashes = VMEnvSpecCodec.chainHashes(provider: provider, baseImageId: baseImageId, spec: spec)

        var cachedLayerIndex = -1
        var restoredSnapshotId: String?
        if !noCache {
            let resolve = try client.sendV2(
                method: "vm.env_resolve_layers",
                params: ["provider": provider, "chain_hashes": chainHashes],
                responseTimeout: 60
            )
            if let layer = resolve["layer"] as? [String: Any],
               let stepIndex = layer["step_index"] as? Int,
               let snapshotId = layer["snapshot_id"] as? String,
               stepIndex >= 0, stepIndex < spec.steps.count {
                cachedLayerIndex = stepIndex
                restoredSnapshotId = snapshotId
            }
        }

        var reports: [VMEnvStepReport] = spec.steps.enumerated().map { index, step in
            VMEnvStepReport(
                index: index,
                name: step.name,
                status: index <= cachedLayerIndex ? "cached" : "pending",
                exitCode: nil,
                durationMs: nil,
                snapshotId: nil,
                chainHash: chainHashes[index]
            )
        }
        let startIndex = cachedLayerIndex + 1

        if !jsonOutput {
            print("env: \(spec.name ?? loaded.path)")
            print("provider: \(provider)  base: \(baseImageId)")
            if cachedLayerIndex >= 0 {
                print("cache: layers 0-\(cachedLayerIndex) cached (\(spec.steps.count - startIndex) of \(spec.steps.count) steps to run)")
            } else {
                print("cache: no cached layers (\(spec.steps.count) steps to run)")
            }
        }

        // Boot the VM: restore the deepest cached layer, or create from base.
        let restoreStartedAt = Date()
        let vmId: String
        if let snapshotId = restoredSnapshotId {
            let response = try client.sendV2(
                method: "vm.restore",
                params: [
                    "snapshot_id": snapshotId,
                    "provider": provider,
                    "idempotency_key": UUID().uuidString.lowercased(),
                ],
                responseTimeout: Self.vmEnvLongOpTimeout
            )
            guard let id = response["id"] as? String, !id.isEmpty else {
                throw CLIError(message: "vm env build: restore of cached layer returned no VM id")
            }
            vmId = id
        } else {
            var params: [String: Any] = [
                "provider": provider,
                "idempotency_key": UUID().uuidString.lowercased(),
            ]
            if usesCustomBase { params["image"] = baseImageId }
            let response = try client.sendV2(
                method: "vm.create",
                params: params,
                responseTimeout: Self.vmEnvLongOpTimeout
            )
            guard let id = response["id"] as? String, !id.isEmpty else {
                throw CLIError(message: "vm env build: VM create returned no id")
            }
            vmId = id
        }
        let restoreMs = Int(Date().timeIntervalSince(restoreStartedAt) * 1000)
        if !jsonOutput {
            print(restoredSnapshotId != nil
                ? "restored cached layer into VM \(vmId) (\(restoreMs)ms)"
                : "created VM \(vmId) (\(restoreMs)ms)")
        }

        var failingStepIndex: Int?
        var failureKind: String?
        // The final step is snapshotted and registered only after verify
        // passes, so `cmux vm env up` can never boot an environment whose
        // verify failed, and a failed verify never strands an unregistered
        // (invisible, secret-bearing) provider snapshot.
        var finalStepRanOK = false

        for index in startIndex..<spec.steps.count {
            let step = spec.steps[index]
            if !jsonOutput { print("step \(index) [\(step.name)] running...") }
            // Stage exactly this step's script (plus the runner) so the layer
            // snapshot taken after it never contains future step/verify text.
            try vmEnvShipScripts(
                vmId: vmId,
                spec: spec,
                stepIndices: [index],
                includeVerify: false,
                client: client
            )
            let started = Date()
            let outcome = try vmEnvRunScript(
                vmId: vmId,
                scriptId: "step-\(index)",
                timeoutMinutes: step.timeoutMinutes ?? Self.vmEnvDefaultStepTimeoutMinutes,
                client: client
            )
            reports[index].durationMs = Int(Date().timeIntervalSince(started) * 1000)
            reports[index].exitCode = outcome.exitCode
            reports[index].logTail = outcome.logTail
            if outcome.status == "ok" {
                reports[index].status = "ok"
                if index == spec.steps.count - 1 {
                    finalStepRanOK = true
                    if !jsonOutput { print("step \(index) [\(step.name)] ok (\(reports[index].durationMs ?? 0)ms, snapshot after verify)") }
                } else {
                    // Snapshot the successful layer and register it in the cache.
                    let snapshotResponse = try client.sendV2(
                        method: "vm.snapshot",
                        params: ["id": vmId, "name": "env-\(String(loaded.digest.prefix(12)))-step-\(index)"],
                        responseTimeout: Self.vmEnvLongOpTimeout
                    )
                    let snapshotId = (snapshotResponse["snapshot_id"] as? String) ?? (snapshotResponse["id"] as? String)
                    if let snapshotId, !snapshotId.isEmpty {
                        reports[index].snapshotId = snapshotId
                        try vmEnvRecordLayer(
                            client: client,
                            provider: provider,
                            baseImageId: baseImageId,
                            chainHash: chainHashes[index],
                            stepIndex: index,
                            stepName: step.name,
                            specDigest: loaded.digest,
                            snapshotId: snapshotId
                        )
                        if !jsonOutput { print("step \(index) [\(step.name)] ok (\(reports[index].durationMs ?? 0)ms, layer cached)") }
                    } else if !jsonOutput {
                        // Step succeeded but the provider returned no snapshot id, so
                        // this layer is not cached and the next build re-runs it.
                        print("step \(index) [\(step.name)] ok (\(reports[index].durationMs ?? 0)ms); snapshot returned no id, layer NOT cached")
                    }
                }
            } else {
                reports[index].status = outcome.status
                failingStepIndex = index
                failureKind = outcome.status
                for later in (index + 1)..<spec.steps.count {
                    reports[later].status = "skipped"
                }
                if !jsonOutput {
                    print("step \(index) [\(step.name)] \(outcome.status) (exit \(outcome.exitCode.map(String.init) ?? "-"))")
                    if let tail = outcome.logTail, !tail.isEmpty {
                        print("--- log tail ---")
                        print(tail)
                        print("----------------")
                    }
                }
            }
            if failingStepIndex != nil { break }
        }

        // Verify commands always run and are never cached as layers. They run
        // BEFORE the final layer snapshot (which only happens after they pass):
        // there is no provider snapshot-delete verb, so snapshotting first
        // would strand an unregistered, secret-bearing snapshot on every
        // verify failure. The documented contract is that verify commands are
        // read-only checks, so their filesystem footprint in the final layer
        // is expected to be nil.
        var verifyReports: [[String: Any]] = []
        if failingStepIndex == nil, !spec.verify.isEmpty {
            // Verify scripts are staged only now, after every step snapshot,
            // so no intermediate layer contains verify text.
            try vmEnvShipScripts(
                vmId: vmId,
                spec: spec,
                stepIndices: [],
                includeVerify: true,
                client: client
            )
            for (index, _) in spec.verify.enumerated() {
                if !jsonOutput { print("verify \(index) running...") }
                let started = Date()
                let outcome = try vmEnvRunScript(
                    vmId: vmId,
                    scriptId: "verify-\(index)",
                    timeoutMinutes: Self.vmEnvDefaultStepTimeoutMinutes,
                    client: client
                )
                verifyReports.append([
                    "index": index,
                    "status": outcome.status,
                    "exitCode": outcome.exitCode ?? NSNull(),
                    "durationMs": Int(Date().timeIntervalSince(started) * 1000),
                    "logTail": outcome.logTail ?? NSNull(),
                ])
                if outcome.status != "ok" {
                    failingStepIndex = spec.steps.count + index
                    failureKind = "verify_failed"
                    if !jsonOutput {
                        print("verify \(index) \(outcome.status) (exit \(outcome.exitCode.map(String.init) ?? "-"))")
                        if let tail = outcome.logTail, !tail.isEmpty {
                            print("--- log tail ---")
                            print(tail)
                            print("----------------")
                        }
                    }
                    break
                }
                if !jsonOutput { print("verify \(index) ok") }
            }
        }

        let ok = failingStepIndex == nil
        if ok {
            let finalIndex = spec.steps.count - 1
            if finalStepRanOK {
                let snapshotResponse = try client.sendV2(
                    method: "vm.snapshot",
                    params: ["id": vmId, "name": "env-\(String(loaded.digest.prefix(12)))-step-\(finalIndex)"],
                    responseTimeout: Self.vmEnvLongOpTimeout
                )
                let snapshotId = (snapshotResponse["snapshot_id"] as? String) ?? (snapshotResponse["id"] as? String)
                if let snapshotId, !snapshotId.isEmpty {
                    reports[finalIndex].snapshotId = snapshotId
                    try vmEnvRecordLayer(
                        client: client,
                        provider: provider,
                        baseImageId: baseImageId,
                        chainHash: chainHashes[finalIndex],
                        stepIndex: finalIndex,
                        stepName: spec.steps[finalIndex].name,
                        specDigest: loaded.digest,
                        snapshotId: snapshotId
                    )
                    if !jsonOutput { print("final layer registered") }
                } else if !jsonOutput {
                    print("final snapshot returned no id; layer NOT cached, `cmux vm env up` will refuse until a re-build caches it")
                }
            } else if cachedLayerIndex == spec.steps.count - 1, let restoredSnapshotId {
                // Fully cached build: refresh the final layer's spec digest so a
                // verify-only edit is re-verified exactly once and `up` unblocks.
                try vmEnvRecordLayer(
                    client: client,
                    provider: provider,
                    baseImageId: baseImageId,
                    chainHash: chainHashes[spec.steps.count - 1],
                    stepIndex: spec.steps.count - 1,
                    stepName: spec.steps[spec.steps.count - 1].name,
                    specDigest: loaded.digest,
                    snapshotId: restoredSnapshotId
                )
            }
        }
        let report: [String: Any] = [
            "ok": ok,
            "specPath": loaded.path,
            "specDigest": loaded.digest,
            "provider": provider,
            "baseImageId": baseImageId,
            "vmId": vmId,
            "cache": [
                "deepestCachedStepIndex": cachedLayerIndex >= 0 ? cachedLayerIndex : NSNull(),
                "restoredSnapshotId": restoredSnapshotId ?? NSNull(),
                "restoreMs": restoreMs,
            ] as [String: Any],
            "steps": reports.map(\.payload),
            "verify": verifyReports,
            "failingStepIndex": failingStepIndex ?? NSNull(),
            "error": failureKind ?? NSNull(),
            "hint": ok
                ? "All layers cached. `cmux vm env up` now boots this environment in seconds."
                : failureKind == "verify_failed"
                    ? "Verify failed, so the final layer was not registered and `cmux vm env up` will refuse this spec. Fix `verify` (or the steps) and re-run `cmux vm env build`; cached layers will not re-run. Inspect with `cmux vm exec \(vmId) -- <cmd>`."
                    : "Fix the failing step in the spec and re-run `cmux vm env build`; cached layers before it will not re-run. Inspect with `cmux vm env logs \(vmId) --step \(failingStepIndex ?? 0)` or `cmux vm exec \(vmId) -- <cmd>`.",
        ]
        if jsonOutput {
            print(jsonString(report))
        } else if ok {
            print("OK env build complete (\(spec.steps.count) layers cached). VM \(vmId) left running.")
            print("Next: cmux vm env up")
        }
        if !ok {
            throw CLIError(message: "env build failed at \(failingStepIndex.map { $0 < spec.steps.count ? "step \($0)" : "verify \($0 - spec.steps.count)" } ?? "?"). VM \(vmId) left running for inspection.")
        }
    }

    private func vmEnvRecordLayer(
        client: SocketClient,
        provider: String,
        baseImageId: String,
        chainHash: String,
        stepIndex: Int,
        stepName: String,
        specDigest: String,
        snapshotId: String
    ) throws {
        _ = try client.sendV2(
            method: "vm.env_record_layer",
            params: [
                "provider": provider,
                "base_image_id": baseImageId,
                "chain_hash": chainHash,
                "step_index": stepIndex,
                "step_name": stepName,
                "spec_digest": specDigest,
                "snapshot_id": snapshotId,
            ],
            responseTimeout: 60
        )
    }
}
