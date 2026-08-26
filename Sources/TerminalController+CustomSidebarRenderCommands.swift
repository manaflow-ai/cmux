import AppKit
import CmuxSettings
import CmuxSwiftRenderUI
import Foundation

extension TerminalController {
    /// Evaluates a custom sidebar, mounts its production content view, and
    /// writes a PNG artifact. Source preparation stays on the socket worker;
    /// only the AppKit/SwiftUI mount crosses to the main actor.
    nonisolated func v2CustomSidebarRender(params: [String: Any]) -> V2CallResult {
        guard let name = v2String(params, "name") else {
            return v2CustomSidebarRenderFailure(
                name: nil,
                path: nil,
                kind: nil,
                message: String(
                    localized: "socket.sidebar.custom.render.missingName",
                    defaultValue: "Render requires a sidebar name."
                )
            )
        }
        guard let width = v2StrictInt(params, "width"),
              let height = v2StrictInt(params, "height") else {
            return v2CustomSidebarRenderFailure(
                name: name,
                path: nil,
                kind: nil,
                message: String(
                    localized: "socket.sidebar.custom.render.invalidSize",
                    defaultValue: "Render width and height must be between 1 and 4096."
                )
            )
        }
        guard let output = v2String(params, "output") else {
            return v2CustomSidebarRenderFailure(
                name: name,
                path: nil,
                kind: nil,
                message: String(
                    localized: "socket.sidebar.custom.render.missingOutput",
                    defaultValue: "Render requires an output path."
                )
            )
        }
        guard width > 0, height > 0,
              width <= CustomSidebarRenderDiagnostic.maximumDimension,
              height <= CustomSidebarRenderDiagnostic.maximumDimension else {
            return v2CustomSidebarRenderFailure(
                name: name,
                path: nil,
                kind: nil,
                message: String(
                    localized: "socket.sidebar.custom.render.invalidSize",
                    defaultValue: "Render width and height must be between 1 and 4096."
                )
            )
        }

        let directory = CmuxExtensionSidebarSelection.customSidebarsDirectory
        guard let fileURL = CustomSidebarValidator()
            .discover(in: directory, name: name)
            .first else {
            return v2CustomSidebarRenderFailure(
                name: name,
                path: directory.appendingPathComponent("\(name).swift").path,
                kind: nil,
                message: String(
                    localized: "socket.sidebar.custom.render.missing",
                    defaultValue: "Sidebar file is missing."
                )
            )
        }

        let diagnostic = CustomSidebarRenderDiagnostic()
        let plan: CustomSidebarRenderPlan
        do {
            plan = try diagnostic.prepare(fileURL: fileURL)
        } catch {
            return v2CustomSidebarRenderFailure(
                name: name,
                path: fileURL.path,
                kind: fileURL.pathExtension.lowercased(),
                message: error.localizedDescription
            )
        }

        let outputURL = URL(
            fileURLWithPath: (output as NSString).expandingTildeInPath,
            isDirectory: false
        )
        let renderResult: Result<CustomSidebarRenderArtifact, Error> = v2MainSync {
            Result {
                try diagnostic.render(
                    plan: plan,
                    width: width,
                    height: height,
                    outputURL: outputURL
                )
            }
        }
        switch renderResult {
        case let .success(artifact):
            return .ok([
                "name": name,
                "path": fileURL.path,
                "kind": plan.kind.rawValue,
                "render_ok": true,
                "mounted": true,
                "artifact_path": artifact.outputURL.path,
                "artifact_format": "png",
                "width": artifact.width,
                "height": artifact.height,
                "visible_pixel_count": artifact.visiblePixelCount,
                "byte_count": artifact.byteCount,
                "error_count": 0,
                "error": NSNull()
            ])
        case let .failure(error):
            return v2CustomSidebarRenderFailure(
                name: name,
                path: fileURL.path,
                kind: plan.kind.rawValue,
                message: error.localizedDescription
            )
        }
    }

    private nonisolated func v2CustomSidebarRenderFailure(
        name: String?,
        path: String?,
        kind: String?,
        message: String
    ) -> V2CallResult {
        .ok([
            "name": v2OrNull(name),
            "path": v2OrNull(path),
            "kind": v2OrNull(kind),
            "render_ok": false,
            "mounted": false,
            "error_count": 1,
            "error": message
        ])
    }
}
