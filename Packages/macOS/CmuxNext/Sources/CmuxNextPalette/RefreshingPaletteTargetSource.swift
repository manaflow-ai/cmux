public import CmuxNextActions

/// A live argument catalog for selected actions, composed with existing target sources.
/// Its cached rows are available immediately; the page owns refresh cancellation.
public final class RefreshingPaletteTargetSource: PaletteTargetSource {
    private let kind: ActionTargetKind
    private let actions: Set<ActionID>
    private let next: any PaletteTargetSource
    private let load: @MainActor () async -> [PaletteTargetOption]
    private var options: [PaletteTargetOption]

    public init(kind: ActionTargetKind, actions: Set<ActionID>, initial: [PaletteTargetOption],
                next: any PaletteTargetSource, load: @escaping @MainActor () async -> [PaletteTargetOption]) {
        (self.kind, self.actions, self.options, self.next, self.load) = (kind, actions, initial, next, load)
    }

    private func owns(_ kind: ActionTargetKind, _ action: ActionID) -> Bool { self.kind == kind && actions.contains(action) }
    public func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] { next.targets(of: kind) }
    public func targets(of kind: ActionTargetKind, for action: ActionID) -> [PaletteTargetOption] {
        owns(kind, action) ? options : next.targets(of: kind, for: action)
    }
    public func targetRefresh(of kind: ActionTargetKind, for action: ActionID) -> (@MainActor () async -> [PaletteTargetOption])? {
        guard owns(kind, action) else { return next.targetRefresh(of: kind, for: action) }
        return { [self] in
            let loaded = await load()
            guard !Task.isCancelled else { return [] }
            options = loaded
            return options
        }
    }
    public func title(of target: ActionTargetRef) -> String? { next.title(of: target) }
    public func currentDescription(of target: ActionTargetRef) -> String? { next.currentDescription(of: target) }
}
