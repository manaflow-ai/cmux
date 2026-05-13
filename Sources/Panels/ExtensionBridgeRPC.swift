import Foundation

protocol ExtensionBridgeHost: AnyObject {
    func v2MainSync<T>(_ body: @MainActor () -> T) -> T
    func withSocketCommandPolicy<T>(
        commandKey: String,
        isV2: Bool,
        params: [String: Any],
        _ body: () -> T
    ) -> T

    func v2RefreshKnownRefs()
    func v2Capabilities() -> [String: Any]
    func v2SystemTree(params: [String: Any]) -> TerminalController.V2CallResult
    func v2WorkspaceList(params: [String: Any]) -> TerminalController.V2CallResult
    func v2WorkspaceCurrent(params: [String: Any]) -> TerminalController.V2CallResult
    func v2PaneList(params: [String: Any]) -> TerminalController.V2CallResult
    func v2PaneSurfaces(params: [String: Any]) -> TerminalController.V2CallResult
    func v2PaneCreate(params: [String: Any]) -> TerminalController.V2CallResult
    func v2SurfaceList(params: [String: Any]) -> TerminalController.V2CallResult
    func v2SurfaceCurrent(params: [String: Any]) -> TerminalController.V2CallResult
    func v2SurfaceFocus(params: [String: Any]) -> TerminalController.V2CallResult
    func v2SurfaceCreate(params: [String: Any]) -> TerminalController.V2CallResult
    func v2SurfaceSplit(params: [String: Any]) -> TerminalController.V2CallResult
    func v2SurfaceClose(params: [String: Any]) -> TerminalController.V2CallResult
    func v2SurfaceSendText(params: [String: Any]) -> TerminalController.V2CallResult
    func v2SurfaceSendKey(params: [String: Any]) -> TerminalController.V2CallResult
}

extension TerminalController: ExtensionBridgeHost {}

struct ExtensionBridgeRPCDispatcher {
    private typealias V2CallResult = TerminalController.V2CallResult

    private let host: ExtensionBridgeHost

    init(host: ExtensionBridgeHost) {
        self.host = host
    }

    func perform(
        method: String,
        params: [String: Any],
        workspaceId: UUID,
        surfaceId: UUID,
        paneId: UUID?
    ) -> [String: Any] {
        let allowedMethods: Set<String> = [
            "system.capabilities",
            "system.tree",
            "workspace.list",
            "workspace.current",
            "pane.list",
            "pane.surfaces",
            "pane.create",
            "surface.list",
            "surface.current",
            "surface.focus",
            "surface.create",
            "surface.split",
            "surface.close",
            "surface.send_text",
            "surface.send_key"
        ]
        guard allowedMethods.contains(method) else {
            return envelope(.err(
                code: "method_not_allowed",
                message: "Extension bridge method is not allowed: \(method)",
                data: nil
            ))
        }

        let scopedResult = scopedParams(
            method: method,
            params: params,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            paneId: paneId
        )
        guard case .ok(let payload) = scopedResult else {
            return envelope(scopedResult)
        }
        guard var scopedParams = payload as? [String: Any] else {
            return envelope(.err(
                code: "internal_error",
                message: "Extension bridge scope resolution returned an invalid payload",
                data: nil
            ))
        }

        let preparedResult = paramsByResolvingBundleIfNeeded(method: method, params: scopedParams)
        guard case .ok(let preparedPayload) = preparedResult else {
            return envelope(preparedResult)
        }
        guard let preparedParams = preparedPayload as? [String: Any] else {
            return envelope(.err(
                code: "internal_error",
                message: "Extension bridge bundle resolution returned an invalid payload",
                data: nil
            ))
        }
        scopedParams = preparedParams

        return host.v2MainSync {
            host.v2RefreshKnownRefs()
            return host.withSocketCommandPolicy(commandKey: method, isV2: true, params: scopedParams) {
                let result: V2CallResult
                switch method {
                case "system.capabilities":
                    result = .ok(host.v2Capabilities())
                case "system.tree":
                    result = host.v2SystemTree(params: scopedParams)
                case "workspace.list":
                    result = host.v2WorkspaceList(params: scopedParams)
                case "workspace.current":
                    result = host.v2WorkspaceCurrent(params: scopedParams)
                case "pane.list":
                    result = host.v2PaneList(params: scopedParams)
                case "pane.surfaces":
                    result = host.v2PaneSurfaces(params: scopedParams)
                case "pane.create":
                    result = host.v2PaneCreate(params: scopedParams)
                case "surface.list":
                    result = host.v2SurfaceList(params: scopedParams)
                case "surface.current":
                    result = host.v2SurfaceCurrent(params: scopedParams)
                case "surface.focus":
                    result = host.v2SurfaceFocus(params: scopedParams)
                case "surface.create":
                    result = host.v2SurfaceCreate(params: scopedParams)
                case "surface.split":
                    result = host.v2SurfaceSplit(params: scopedParams)
                case "surface.close":
                    result = host.v2SurfaceClose(params: scopedParams)
                case "surface.send_text":
                    result = host.v2SurfaceSendText(params: scopedParams)
                case "surface.send_key":
                    result = host.v2SurfaceSendKey(params: scopedParams)
                default:
                    result = .err(
                        code: "method_not_allowed",
                        message: "Extension bridge method is not allowed: \(method)",
                        data: nil
                    )
                }
                return envelope(result)
            }
        }
    }

    private func paramsByResolvingBundleIfNeeded(
        method: String,
        params: [String: Any]
    ) -> V2CallResult {
        let extensionCreationMethods: Set<String> = [
            "pane.create",
            "surface.create",
            "surface.split"
        ]
        guard extensionCreationMethods.contains(method) else {
            return .ok(params)
        }
        if params[TerminalController.v2ResolvedExtensionBundleParamKey] is ExtensionBundleDescriptor {
            return .ok(params)
        }
        let panelTypeResult = Self.panelType(params["type"])
        guard case .ok(let rawPanelType) = panelTypeResult else {
            return panelTypeResult
        }
        guard let panelType = rawPanelType as? PanelType,
              panelType == .extensionPane else {
            return .ok(params)
        }
        guard let bundlePath = Self.trimmedString(params["bundle"])
            ?? Self.trimmedString(params["bundle_path"]) else {
            return .err(code: "invalid_params", message: "Missing bundle path for extension surface", data: nil)
        }
        do {
            var preparedParams = params
            let bundle = try ExtensionBundleDescriptor.resolve(path: bundlePath)
            guard ExtensionBundleTrustStore.shared.isTrusted(bundle) else {
                return .err(
                    code: "untrusted_extension_bundle",
                    message: "Extension bundle is not trusted",
                    data: ["bundle": bundlePath]
                )
            }
            preparedParams[TerminalController.v2ResolvedExtensionBundleParamKey] = bundle
            return .ok(preparedParams)
        } catch {
            return .err(
                code: "invalid_params",
                message: error.localizedDescription,
                data: ["bundle": bundlePath]
            )
        }
    }

    private static func panelType(_ rawValue: Any?) -> V2CallResult {
        guard let rawType = trimmedString(rawValue) else {
            return .ok(PanelType.terminal)
        }
        guard let panelType = PanelType.userInputValue(rawType) else {
            return .err(
                code: "invalid_params",
                message: "Unknown surface type: \(rawType)",
                data: ["type": rawType]
            )
        }
        return .ok(panelType)
    }

    private static func trimmedString(_ rawValue: Any?) -> String? {
        guard let string = rawValue as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func scopedParams(
        method: String,
        params: [String: Any],
        workspaceId: UUID,
        surfaceId: UUID,
        paneId: UUID?
    ) -> V2CallResult {
        var scopedParams = params
        if scopedParams["workspace_id"] == nil {
            scopedParams["workspace_id"] = (scopedParams["workspace"] as? String) ?? workspaceId.uuidString
        }
        scopedParams.removeValue(forKey: "workspace")

        if scopedParams["surface_id"] == nil,
           let rawSurface = scopedParams["surface"] as? String {
            scopedParams["surface_id"] = rawSurface
        }
        scopedParams.removeValue(forKey: "surface")

        if scopedParams["pane_id"] == nil,
           let rawPane = scopedParams["pane"] as? String {
            scopedParams["pane_id"] = rawPane
        }
        scopedParams.removeValue(forKey: "pane")

        let workspaceString = workspaceId.uuidString
        let surfaceString = surfaceId.uuidString
        let paneString = paneId?.uuidString

        func stringValue(_ value: Any?) -> String? {
            guard let string = value as? String else { return nil }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        func enforceScope(_ key: String, expected: String) -> V2CallResult? {
            if let existing = stringValue(scopedParams[key]), existing != expected {
                return .err(
                    code: "forbidden_scope",
                    message: "Extension bridge method \(method) cannot target a different \(key)",
                    data: ["expected": expected, "received": existing]
                )
            }
            scopedParams[key] = expected
            return nil
        }

        let hostSurfaceMethods: Set<String> = [
            "pane.create",
            "surface.focus",
            "surface.split",
            "surface.close",
            "surface.send_text",
            "surface.send_key"
        ]
        let hostPaneMethods: Set<String> = [
            "surface.create"
        ]
        if hostSurfaceMethods.contains(method) || hostPaneMethods.contains(method) {
            if let error = enforceScope("workspace_id", expected: workspaceString) {
                return error
            }
        }
        if hostSurfaceMethods.contains(method),
           let error = enforceScope("surface_id", expected: surfaceString) {
            return error
        }
        if hostPaneMethods.contains(method) {
            guard let paneString else {
                return .err(
                    code: "missing_scope",
                    message: "Extension bridge method \(method) requires a host pane",
                    data: nil
                )
            }
            if let error = enforceScope("pane_id", expected: paneString) {
                return error
            }
        }

        switch method {
        case "pane.surfaces":
            if scopedParams["pane_id"] == nil, let paneId {
                scopedParams["pane_id"] = paneId.uuidString
            }
        default:
            break
        }

        return .ok(scopedParams)
    }

    private func envelope(_ result: V2CallResult) -> [String: Any] {
        switch result {
        case .ok(let payload):
            return [
                "ok": true,
                "result": payload
            ]
        case .err(let code, let message, let data):
            var error: [String: Any] = [
                "code": code,
                "message": message
            ]
            error["data"] = data ?? NSNull()
            return [
                "ok": false,
                "error": error
            ]
        }
    }
}
