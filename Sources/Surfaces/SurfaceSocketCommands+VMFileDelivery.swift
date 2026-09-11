import Foundation

extension TerminalController {
    /// `vm.file_put {id, path, mode?, data_base64}` → one file lands on the machine at
    /// `path` (mode `mode`, default 600) over its link, through the in-VM
    /// `cmux file receive` (see `CloudFileDelivery`): never through `vm.exec`, a command
    /// line, or a terminal's visible screen. Backs `cmux vm push --secret`.
    /// Result: `{machine, path, mode, bytes, transport: "link"}`.
    nonisolated func socketWorkerVMFilePutResponse(id: Any?, params: [String: Any]) -> String {
        guard !ManagedFileTransferPolicy.isDisabled else {
            return v2Error(id: id, code: "file_transfer_disabled", message: ManagedFileTransferPolicy.disabledMessage)
        }
        guard let vmId = Self.surfaceString(params["id"]), !vmId.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "vm.file_put requires `id`. Run `cmux vm ls` to find one.")
        }
        guard let path = Self.surfaceString(params["path"]), !path.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "vm.file_put requires `path`: where the file lands on the machine (relative paths resolve against its home).")
        }
        let mode = Self.surfaceString(params["mode"]) ?? CloudFileDelivery.defaultMode
        guard CloudFileDelivery.isValidMode(mode) else {
            return v2Error(id: id, code: "invalid_params", message: "vm.file_put: `mode` must be three or four octal digits (e.g. 600, 0644).")
        }
        guard let encoded = params["data_base64"] as? String, let data = Data(base64Encoded: encoded) else {
            return v2Error(id: id, code: "invalid_params", message: "vm.file_put requires `data_base64`: the file's bytes, base64-encoded.")
        }
        guard !data.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "vm.file_put: the file is empty; nothing to deliver.")
        }
        guard data.count <= CloudFileDelivery.maxPayloadBytes else {
            return v2Error(id: id, code: "invalid_params", message: "vm.file_put: \(data.count) bytes exceeds the \(CloudFileDelivery.maxPayloadBytes)-byte limit for link delivery; use `cmux vm push` without --secret for large, non-secret files.")
        }
        let request = CloudFileDelivery.Request(path: path, mode: mode, data: data)
        return v2VmCall(id: id, timeoutSeconds: 240) {
            let provider = try await Self.cloudTuiProvider(machineID: vmId, catalog: await SurfaceCatalog.shared)
            let outcome = try await provider.deliverFile(request)
            var bytes = data.count
            var reportedPath: Any = path
            var reportedMode: Any = mode
            if case .ok(let count, let atPath, let withMode) = outcome {
                bytes = count
                if let atPath { reportedPath = atPath }
                if let withMode { reportedMode = withMode }
            }
            return ["machine": vmId, "path": reportedPath, "mode": reportedMode, "bytes": bytes, "transport": "link"]
        }
    }
}
