import CmuxFoundation
import Foundation

/// `surface.offer_code_block`: a process in a terminal pane hands the user a
/// block of code (usually a shell command) as a card with Copy and, for shell
/// blocks, Run. Run opens a new split and types the command there; nothing
/// ever executes without the user pressing Return in that split.
///
/// Params:
/// - `surface_id` (required): the terminal the card belongs to. The CLI
///   fills it from `CMUX_SURFACE_ID`, so a block lands on its caller's pane.
/// - `text`: the exact block text. Required unless `clear` is set.
/// - `language`: fence tag (`bash`, `json`, ...). Shell tags enable Run.
/// - `label`: short title for the card.
/// - `runnable`: overrides the language's Run default.
/// - `clear`: remove this pane's offered blocks instead of adding one.
///
/// Not focus-intent: the card appears without selecting the workspace,
/// raising the window or moving focus.
extension TerminalController {
    static let codeBlockTextLimit = 64 * 1024
    static let codeBlockLabelLimit = 200

    func v2SurfaceOfferCodeBlock(params: [String: Any]) -> V2CallResult {
        guard let surfaceID = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        let clear = v2Bool(params, "clear") == true
        let text = v2String(params, "text") ?? ""
        if !clear {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .err(code: "invalid_params", message: "Missing text", data: nil)
            }
            guard text.utf8.count <= Self.codeBlockTextLimit else {
                return .err(
                    code: "invalid_params",
                    message: "text exceeds \(Self.codeBlockTextLimit) bytes",
                    data: ["limit": Self.codeBlockTextLimit]
                )
            }
        }
        let label = v2String(params, "label").map { String($0.prefix(Self.codeBlockLabelLimit)) }
        let block = TerminalCodeBlock(
            text: text,
            language: v2String(params, "language"),
            label: label,
            origin: .offered,
            runnable: v2Bool(params, "runnable")
        )
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let found: (workspaceID: UUID, offered: Int)? = v2MainSync {
            guard let workspace = tabManager.tabs.first(where: { $0.panels[surfaceID] != nil }),
                  let panel = workspace.panels[surfaceID] as? TerminalPanel else { return nil }
            let controller = panel.surface.hostedView.codeBlocks
            if clear {
                controller.dismissOffered()
            } else {
                controller.offer(block)
            }
            return (workspace.id, controller.offered.count)
        }
        guard let found else {
            return .err(
                code: "not_found",
                message: "Terminal surface not found",
                data: ["surface_id": surfaceID.uuidString]
            )
        }
        var result: [String: Any] = [
            "workspace_id": found.workspaceID.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: found.workspaceID),
            "surface_id": surfaceID.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceID),
            "offered": found.offered,
        ]
        if !clear {
            result["block_id"] = block.id
            result["runnable"] = block.isRunnable
            result["language"] = v2OrNull(block.language)
        }
        return .ok(result)
    }
}
