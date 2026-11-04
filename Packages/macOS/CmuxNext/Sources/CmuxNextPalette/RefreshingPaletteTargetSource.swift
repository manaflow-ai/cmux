public import CmuxNextActions

/// A live argument catalog for selected actions, composed with existing target sources.
/// Its cached rows are available immediately; the page owns refresh cancellation.
public final class RefreshingPaletteTargetSource: PaletteTargetSource {
    private let kind: ActionTargetKind
    private let actions: Set<ActionID>
    private let next: any PaletteTargetSource
    private let load: @MainActor () async -> [PaletteTargetOption]
    private let updates: (@MainActor () -> AsyncStream<[PaletteTargetOption]>)?
    private var options: [PaletteTargetOption]

    public init(kind: ActionTargetKind, actions: Set<ActionID>, initial: [PaletteTargetOption],
                next: any PaletteTargetSource, load: @escaping @MainActor () async -> [PaletteTargetOption]) {
        (self.kind, self.actions, self.options, self.next, self.load) = (kind, actions, initial, next, load)
        self.updates = nil
    }

    /// A source whose inventory comes over time, each list of rows made into options by `option`;
    /// the last list is kept for the next open.
    public init<Row>(kind: ActionTargetKind, actions: Set<ActionID>, initial: [PaletteTargetOption],
                     next: any PaletteTargetSource, updates rows: @escaping @MainActor () -> AsyncStream<[Row]>,
                     option: @escaping @MainActor (Row) -> PaletteTargetOption) {
        let updates: @MainActor () -> AsyncStream<[PaletteTargetOption]> = {
            let (stream, continuation) = AsyncStream.makeStream(of: [PaletteTargetOption].self, bufferingPolicy: .bufferingNewest(1))
            // task-owner: maps one open's row lists; ends with the stream's consumer
            let task = Task { @MainActor in
                for await list in rows() { continuation.yield(list.map(option)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
            return stream
        }
        (self.kind, self.actions, self.options, self.next, self.updates) = (kind, actions, initial, next, updates)
        self.load = {
            var last: [PaletteTargetOption] = []
            for await options in updates() { last = options }
            return last
        }
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
    public func targetUpdates(of kind: ActionTargetKind, for action: ActionID) -> (@MainActor () -> AsyncStream<[PaletteTargetOption]>)? {
        guard owns(kind, action) else { return next.targetUpdates(of: kind, for: action) }
        guard let updates else { return nil }
        return { [self] in
            let (stream, continuation) = AsyncStream.makeStream(of: [PaletteTargetOption].self, bufferingPolicy: .bufferingNewest(1))
            // task-owner: forwards one open's lists; ends with the stream's consumer
            let task = Task { @MainActor in
                for await options in updates() {
                    self.options = options
                    continuation.yield(options)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
            return stream
        }
    }

    public func title(of target: ActionTargetRef) -> String? { next.title(of: target) }
    public func currentDescription(of target: ActionTargetRef) -> String? { next.currentDescription(of: target) }
}
