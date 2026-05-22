import Foundation

protocol ExtensionBridgeHost: AnyObject {
    func v2MainSync<T>(_ body: @MainActor () -> T) -> T
    func withSocketCommandPolicy<T>(
        commandKey: String,
        isV2: Bool,
        params: [String: Any],
        _ body: () -> T
    ) -> T

    @MainActor func v2RefreshKnownRefs()
    @MainActor func v2Capabilities() -> [String: Any]
    @MainActor func v2SystemTree(params: [String: Any]) -> TerminalController.V2CallResult
    @MainActor func v2WorkspaceList(params: [String: Any]) -> TerminalController.V2CallResult
    @MainActor func v2WorkspaceCurrent(params: [String: Any]) -> TerminalController.V2CallResult
    @MainActor func v2PaneList(params: [String: Any]) -> TerminalController.V2CallResult
    @MainActor func v2PaneSurfaces(params: [String: Any]) -> TerminalController.V2CallResult
    @MainActor func v2PaneCreate(params: [String: Any]) -> TerminalController.V2CallResult
    @MainActor func v2SurfaceList(params: [String: Any]) -> TerminalController.V2CallResult
    @MainActor func v2SurfaceCurrent(params: [String: Any]) -> TerminalController.V2CallResult
    @MainActor func v2SurfaceFocus(params: [String: Any]) -> TerminalController.V2CallResult
    @MainActor func v2SurfaceCreate(params: [String: Any]) -> TerminalController.V2CallResult
    @MainActor func v2SurfaceSplit(params: [String: Any]) -> TerminalController.V2CallResult
    @MainActor func v2SurfaceClose(params: [String: Any]) -> TerminalController.V2CallResult
    @MainActor func v2SurfaceSendText(params: [String: Any]) -> TerminalController.V2CallResult
    @MainActor func v2SurfaceSendKey(params: [String: Any]) -> TerminalController.V2CallResult
}

extension TerminalController: ExtensionBridgeHost {}

struct ExtensionBridgeRPCDispatcher {
    private typealias V2CallResult = TerminalController.V2CallResult

    private enum BridgeMethod: String {
        case systemCapabilities = "system.capabilities"
        case systemTree = "system.tree"
        case workspaceList = "workspace.list"
        case workspaceCurrent = "workspace.current"
        case paneList = "pane.list"
        case paneSurfaces = "pane.surfaces"
        case paneCreate = "pane.create"
        case surfaceList = "surface.list"
        case surfaceCurrent = "surface.current"
        case surfaceFocus = "surface.focus"
        case surfaceCreate = "surface.create"
        case surfaceSplit = "surface.split"
        case surfaceClose = "surface.close"
        case surfaceSendText = "surface.send_text"
        case surfaceSendKey = "surface.send_key"
    }

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
        guard let bridgeMethod = BridgeMethod(rawValue: method) else {
            return envelope(Self.methodNotAllowed(method))
        }

        let scopedResult = scopedParams(
            method: bridgeMethod,
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

        let preparedResult = paramsByResolvingBundleIfNeeded(method: bridgeMethod, params: scopedParams)
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
            return host.withSocketCommandPolicy(
                commandKey: bridgeMethod.rawValue,
                isV2: true,
                params: scopedParams
            ) {
                let result: V2CallResult
                switch bridgeMethod {
                case .systemCapabilities:
                    result = .ok(host.v2Capabilities())
                case .systemTree:
                    result = host.v2SystemTree(params: scopedParams)
                case .workspaceList:
                    result = host.v2WorkspaceList(params: scopedParams)
                case .workspaceCurrent:
                    result = host.v2WorkspaceCurrent(params: scopedParams)
                case .paneList:
                    result = host.v2PaneList(params: scopedParams)
                case .paneSurfaces:
                    result = host.v2PaneSurfaces(params: scopedParams)
                case .paneCreate:
                    result = host.v2PaneCreate(params: scopedParams)
                case .surfaceList:
                    result = host.v2SurfaceList(params: scopedParams)
                case .surfaceCurrent:
                    result = host.v2SurfaceCurrent(params: scopedParams)
                case .surfaceFocus:
                    result = host.v2SurfaceFocus(params: scopedParams)
                case .surfaceCreate:
                    result = host.v2SurfaceCreate(params: scopedParams)
                case .surfaceSplit:
                    result = host.v2SurfaceSplit(params: scopedParams)
                case .surfaceClose:
                    result = host.v2SurfaceClose(params: scopedParams)
                case .surfaceSendText:
                    result = host.v2SurfaceSendText(params: scopedParams)
                case .surfaceSendKey:
                    result = host.v2SurfaceSendKey(params: scopedParams)
                }
                return envelope(result)
            }
        }
    }

    private func paramsByResolvingBundleIfNeeded(
        method: BridgeMethod,
        params: [String: Any]
    ) -> V2CallResult {
        let extensionCreationMethods: Set<BridgeMethod> = [
            .paneCreate,
            .surfaceCreate,
            .surfaceSplit
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
            return .err(
                code: "invalid_params",
                message: ExtensionBundleResolveError.missingBundlePathMessage,
                data: nil
            )
        }
        do {
            var preparedParams = params
            let bundle = try ExtensionBundleDescriptor.resolve(path: bundlePath)
            guard ExtensionBundleTrustStore.shared.isTrusted(bundle) else {
                return .err(
                    code: "untrusted_extension_bundle",
                    message: ExtensionBundleResolveError.untrustedBundleMessage,
                    data: ["reason": "untrusted_bundle"]
                )
            }
            preparedParams[TerminalController.v2ResolvedExtensionBundleParamKey] = bundle
            return .ok(preparedParams)
        } catch {
            return .err(
                code: "invalid_params",
                message: ExtensionBundleResolveError.userFacingMessage(for: error),
                data: ["reason": ExtensionBundleResolveError.bridgeReasonCode(for: error)]
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
        method: BridgeMethod,
        params: [String: Any],
        workspaceId: UUID,
        surfaceId: UUID,
        paneId: UUID?
    ) -> V2CallResult {
        var workingParams = params
        if workingParams["workspace_id"] == nil {
            workingParams["workspace_id"] = (workingParams["workspace"] as? String) ?? workspaceId.uuidString
        }
        workingParams.removeValue(forKey: "workspace")

        if workingParams["surface_id"] == nil,
           let rawSurface = workingParams["surface"] as? String {
            workingParams["surface_id"] = rawSurface
        }
        workingParams.removeValue(forKey: "surface")

        if workingParams["pane_id"] == nil,
           let rawPane = workingParams["pane"] as? String {
            workingParams["pane_id"] = rawPane
        }
        workingParams.removeValue(forKey: "pane")

        let workspaceString = workspaceId.uuidString
        let surfaceString = surfaceId.uuidString
        let paneString = paneId?.uuidString

        func stringValue(_ value: Any?) -> String? {
            guard let string = value as? String else { return nil }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        func scopeValueMatches(_ existing: String, expected: String) -> Bool {
            if let existingUUID = UUID(uuidString: existing),
               let expectedUUID = UUID(uuidString: expected) {
                return existingUUID == expectedUUID
            }
            return existing == expected
        }

        func enforceScope(_ key: String, expected: String) -> V2CallResult? {
            if let existing = stringValue(workingParams[key]), !scopeValueMatches(existing, expected: expected) {
                return .err(
                    code: "forbidden_scope",
                    message: "Extension bridge method \(method.rawValue) cannot target a different \(key)",
                    data: ["expected": expected, "received": existing]
                )
            }
            workingParams[key] = expected
            return nil
        }

        let hostSurfaceMethods: Set<BridgeMethod> = [
            .paneCreate,
            .surfaceFocus,
            .surfaceSplit,
            .surfaceClose,
            .surfaceSendText,
            .surfaceSendKey
        ]
        let hostPaneMethods: Set<BridgeMethod> = [.surfaceCreate]
        if hostSurfaceMethods.contains(method)
            || hostPaneMethods.contains(method) {
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
                    message: "Extension bridge method \(method.rawValue) requires a host pane",
                    data: nil
                )
            }
            if let error = enforceScope("pane_id", expected: paneString) {
                return error
            }
        }

        switch method {
        case .paneSurfaces:
            if workingParams["pane_id"] == nil, let paneId {
                workingParams["pane_id"] = paneId.uuidString
            }
        default:
            break
        }

        return .ok(workingParams)
    }

    private static func methodNotAllowed(_ method: String) -> V2CallResult {
        .err(
            code: "method_not_allowed",
            message: "Extension bridge method is not allowed: \(method)",
            data: nil
        )
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
