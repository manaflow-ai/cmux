import Foundation

/// `action.run` targets in the old CLI's forms: `surface:N` (shown as
/// `tab:N` by the old CLI), `pane:N`, `workspace:N`, `window:N` and old
/// UUIDs resolve to the App's model ids, so `cmux tab reload --target
/// surface:2` names the same tab `list-panels` printed. The router has
/// already split a known kind prefix (`pane:2` arrives as pane `2`); an
/// unknown one (`surface:2`) arrives whole as the id of the action's kind.
extension CompatService {
    func resolveActionTarget(_ ref: ControlTargetRef, deadline: ContinuousClock.Instant) async throws -> ControlTargetRef {
        guard let form = CompatTargetForm(ref) else { return ref }
        let world = try await world(deadline: deadline)
        do {
            return try form.resolve(in: world, refs: refs)
        } catch let error as ControlError {
            // An old UUID may also be a native id the App knows (workspace
            // keys are UUIDs): only a short ref fails loudly.
            if form.isUUID { return ref }
            throw error
        }
    }
}

/// One target id that may be an old-CLI handle.
struct CompatTargetForm {
    let kind: String
    /// The handle in `kind:N` or UUID form for `CompatWorld.resolve…`.
    let handle: String
    let handleKind: CompatRefRegistry.Kind?
    let isUUID: Bool

    init?(_ ref: ControlTargetRef) {
        guard ["tab", "pane", "workspace", "window"].contains(ref.kind) else { return nil }
        var text = ref.id.trimmingCharacters(in: .whitespaces)
        kind = ref.kind
        // `build-box:surface:3` (plans/cmux-next/data-model.md 1.3): the
        // qualifier rides on the handle; `CompatWorld` resolves it.
        var qualifier = ""
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
        if pieces.count == 3, !pieces[0].isEmpty, Int(pieces[2]) != nil,
           CompatRefRegistry.Kind(rawValue: pieces[1].lowercased()) != nil || pieces[1].lowercased() == "tab" {
            qualifier = pieces[0] + ":"
            text = pieces[1] + ":" + pieces[2]
        }
        if CompatUUID.canonical(text) != nil {
            handle = text
            handleKind = nil
            isUUID = true
            return
        }
        isUUID = false
        // `tab:N` is how the old CLI displays `surface:N`.
        let aliased = text.lowercased().hasPrefix("tab:") ? "surface:" + text.dropFirst(4) : text
        if let (parsed, number) = CompatRefRegistry.parse(aliased) {
            handleKind = parsed
            handle = "\(qualifier)\(parsed.rawValue):\(number)"
        } else if qualifier.isEmpty, let number = Int(text), number >= 0 {
            let own: CompatRefRegistry.Kind = switch ref.kind {
            case "pane": .pane
            case "workspace": .workspace
            case "window": .window
            default: .surface
            }
            handleKind = own
            handle = "\(own.rawValue):\(number)"
        } else {
            return nil
        }
    }

    func resolve(in world: CompatWorld, refs: CompatRefRegistry) throws -> ControlTargetRef {
        let surface = { try world.resolveSurface(handle, in: nil, refs: refs) }
        let pane = { try world.resolvePane(handle, in: nil, refs: refs) }
        switch kind {
        case "tab":
            return CompatTargets.tab(try surface())
        case "pane":
            if handleKind == .surface, let found = world.panes[try surface().paneUUID] { return CompatTargets.pane(found) }
            return CompatTargets.pane(try pane())
        case "workspace":
            let uuid: String? = switch handleKind {
            case .surface: try surface().workspaceUUID
            case .pane: try pane().workspaceUUID
            default: nil
            }
            if let uuid, let found = world.workspace(uuid) { return CompatTargets.workspace(found) }
            return CompatTargets.workspace(try world.resolveWorkspace(handle, refs: refs))
        default:
            return ControlTargetRef(kind: "window", id: try world.resolveWindow(handle, refs: refs).modelID)
        }
    }
}
