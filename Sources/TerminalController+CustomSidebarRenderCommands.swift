import AppKit
import CmuxControlSocket
import CmuxSettings
import CmuxSwiftRenderUI
import Foundation
import OSLog

private nonisolated let customSidebarRenderLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "CustomSidebarRender"
)

private nonisolated struct CustomSidebarRenderRequest: Sendable {
    let name: String
    let fileURL: URL
    let plan: CustomSidebarRenderPlan
    let width: Int
    let height: Int
    let outputURL: URL
}

private nonisolated struct CustomSidebarRenderFailure: Sendable {
    let name: String?
    let path: String?
    let kind: String?
    let message: String
}

private nonisolated enum CustomSidebarRenderPreparation: Sendable {
    case ready(CustomSidebarRenderRequest)
    case failure(CustomSidebarRenderFailure)
}

private nonisolated enum CustomSidebarRenderExecution: Sendable {
    case success(CustomSidebarRenderArtifact)
    case failure(String)
}

extension TerminalController {
    /// Evaluates, mounts, and renders a custom sidebar on the main actor.
    /// Socket connections use ``v2CustomSidebarRenderAsync(request:)`` so the
    /// worker task suspends while AppKit performs the mount instead of waiting
    /// synchronously on the main queue. This synchronous entry remains only
    /// for direct main-actor in-process callers; synchronous socket-worker
    /// callers receive an explicit async-required response.
    @MainActor
    func v2CustomSidebarRender(params: [String: Any]) -> V2CallResult {
        switch prepareCustomSidebarRender(params: params) {
        case .failure(let failure):
            return Self.legacyV2CallResult(Self.customSidebarRenderFailureResult(failure))
        case .ready(let request):
            return Self.legacyV2CallResult(
                Self.customSidebarRenderResult(
                    request: request,
                    execution: executeCustomSidebarRender(request)
                )
            )
        }
    }

    /// Prepares a render off the main actor, then suspends until the main
    /// actor has mounted and captured the sidebar. The response is encoded
    /// after the await on the socket connection task.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func v2CustomSidebarRenderAsync(request: ControlRequest) async -> String {
        let bridgedParams = request.params.mapValues(\.foundationObject)
        let result: ControlCallResult
        switch prepareCustomSidebarRender(params: bridgedParams) {
        case .failure(let failure):
            result = Self.customSidebarRenderFailureResult(failure)
        case .ready(let renderRequest):
            let execution = await v2MainAsync {
                self.executeCustomSidebarRender(renderRequest)
            }
            result = Self.customSidebarRenderResult(
                request: renderRequest,
                execution: execution
            )
        }
        return Self.v2Encoder.response(id: request.id, result)
    }

    private nonisolated func prepareCustomSidebarRender(
        params: [String: Any]
    ) -> CustomSidebarRenderPreparation {
        let maximumDimension = CustomSidebarRenderDiagnostic.maximumDimension
        guard let name = v2String(params, "name") else {
            return .failure(
                CustomSidebarRenderFailure(
                    name: nil,
                    path: nil,
                    kind: nil,
                    message: String(
                        localized: "socket.sidebar.custom.render.missingName",
                        defaultValue: "Render requires a sidebar name."
                    )
                )
            )
        }
        guard let width = v2StrictInt(params, "width"),
              let height = v2StrictInt(params, "height") else {
            return .failure(
                CustomSidebarRenderFailure(
                    name: name,
                    path: nil,
                    kind: nil,
                    message: Self.customSidebarRenderInvalidSizeMessage(
                        maximumDimension: maximumDimension
                    )
                )
            )
        }
        guard let output = v2String(params, "output") else {
            return .failure(
                CustomSidebarRenderFailure(
                    name: name,
                    path: nil,
                    kind: nil,
                    message: String(
                        localized: "socket.sidebar.custom.render.missingOutput",
                        defaultValue: "Render requires an output path."
                    )
                )
            )
        }
        guard width > 0, height > 0,
              width <= maximumDimension,
              height <= maximumDimension else {
            return .failure(
                CustomSidebarRenderFailure(
                    name: name,
                    path: nil,
                    kind: nil,
                    message: Self.customSidebarRenderInvalidSizeMessage(
                        maximumDimension: maximumDimension
                    )
                )
            )
        }

        let directory = CmuxExtensionSidebarSelection.customSidebarsDirectory
        guard let fileURL = CustomSidebarValidator()
            .discover(in: directory, name: name)
            .first else {
            return .failure(
                CustomSidebarRenderFailure(
                    name: name,
                    path: directory.appendingPathComponent("\(name).swift").path,
                    kind: nil,
                    message: String(
                        localized: "socket.sidebar.custom.render.missing",
                        defaultValue: "Sidebar file is missing."
                    )
                )
            )
        }

        let diagnostic = CustomSidebarRenderDiagnostic()
        let plan: CustomSidebarRenderPlan
        do {
            plan = try diagnostic.prepare(fileURL: fileURL)
        } catch {
            return .failure(
                CustomSidebarRenderFailure(
                    name: name,
                    path: fileURL.path,
                    kind: fileURL.pathExtension.lowercased(),
                    message: customSidebarRenderFailureMessage(
                        error,
                        stage: "prepare",
                        path: fileURL.path
                    )
                )
            )
        }

        return .ready(
            CustomSidebarRenderRequest(
                name: name,
                fileURL: fileURL,
                plan: plan,
                width: width,
                height: height,
                outputURL: URL(
                    fileURLWithPath: (output as NSString).expandingTildeInPath,
                    isDirectory: false
                )
            )
        )
    }

    @MainActor
    private func executeCustomSidebarRender(
        _ request: CustomSidebarRenderRequest
    ) -> CustomSidebarRenderExecution {
        do {
            let artifact = try CustomSidebarRenderDiagnostic().render(
                plan: request.plan,
                width: request.width,
                height: request.height,
                outputURL: request.outputURL
            )
            return .success(artifact)
        } catch {
            return .failure(
                customSidebarRenderFailureMessage(
                    error,
                    stage: "render",
                    path: request.fileURL.path
                )
            )
        }
    }

    private nonisolated static func customSidebarRenderResult(
        request: CustomSidebarRenderRequest,
        execution: CustomSidebarRenderExecution
    ) -> ControlCallResult {
        switch execution {
        case .success(let artifact):
            return .ok(.object([
                "name": .string(request.name),
                "path": .string(request.fileURL.path),
                "kind": .string(request.plan.kind.rawValue),
                "render_ok": .bool(true),
                "mounted": .bool(true),
                "artifact_path": .string(artifact.outputURL.path),
                "artifact_format": .string("png"),
                "width": .int(Int64(artifact.width)),
                "height": .int(Int64(artifact.height)),
                "visible_pixel_count": .int(Int64(artifact.visiblePixelCount)),
                "byte_count": .int(Int64(artifact.byteCount)),
                "error_count": .int(0),
                "error": .null,
            ]))
        case .failure(let message):
            return Self.customSidebarRenderFailureResult(
                CustomSidebarRenderFailure(
                    name: request.name,
                    path: request.fileURL.path,
                    kind: request.plan.kind.rawValue,
                    message: message
                )
            )
        }
    }

    private nonisolated static func customSidebarRenderFailureResult(
        _ failure: CustomSidebarRenderFailure
    ) -> ControlCallResult {
        .ok(.object([
            "name": jsonStringOrNull(failure.name),
            "path": jsonStringOrNull(failure.path),
            "kind": jsonStringOrNull(failure.kind),
            "render_ok": .bool(false),
            "mounted": .bool(false),
            "error_count": .int(1),
            "error": .string(failure.message),
        ]))
    }

    private nonisolated static func jsonStringOrNull(_ value: String?) -> JSONValue {
        guard let value else { return .null }
        return .string(value)
    }

    private nonisolated static func legacyV2CallResult(
        _ result: ControlCallResult
    ) -> V2CallResult {
        switch result {
        case .ok(let payload):
            return .ok(payload.foundationObject)
        case .err(let code, let message, let data):
            return .err(
                code: code,
                message: message,
                data: data?.foundationObject
            )
        }
    }

    private nonisolated static func customSidebarRenderInvalidSizeMessage(
        maximumDimension: Int
    ) -> String {
        String(
            format: String(
                localized: "socket.sidebar.custom.render.invalidSize",
                defaultValue: "Render width and height must be between 1 and %d."
            ),
            maximumDimension
        )
    }

    private nonisolated func customSidebarRenderFailureMessage(
        _ error: Error,
        stage: String,
        path: String
    ) -> String {
        customSidebarRenderLogger.error(
            "custom sidebar render failed stage=\(stage, privacy: .public) path=\(path, privacy: .private(mask: .hash)) detail=\(String(describing: error), privacy: .private)"
        )
        if let diagnosticError = error as? CustomSidebarRenderDiagnosticError,
           let message = diagnosticError.errorDescription {
            return message
        }
        return String(
            localized: "socket.sidebar.custom.render.failed",
            defaultValue: "Sidebar render failed. Check the sidebar file and output path, then try again."
        )
    }
}
