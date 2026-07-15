public import AppKit

@MainActor
public final class CmuxPopoverVisibleUpdateScheduler {
    private var pendingUpdate: (@MainActor () -> Void)?
    private var scheduledTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init() {}

    deinit {
        scheduledTask?.cancel()
    }

    public func schedule(_ update: @escaping @MainActor () -> Void) {
        pendingUpdate = update
        guard scheduledTask == nil else { return }
        let generation = self.generation
        scheduledTask = Task { @MainActor [weak self] in
            self?.flush(ifCurrent: generation)
        }
    }

    public func cancel() {
        generation &+= 1
        scheduledTask?.cancel()
        scheduledTask = nil
        pendingUpdate = nil
    }

    private func flush(ifCurrent generation: UInt64) {
        guard generation == self.generation, !Task.isCancelled else { return }
        scheduledTask = nil
        guard let pendingUpdate else { return }
        self.pendingUpdate = nil
        pendingUpdate()
    }
}

@MainActor
public enum CmuxPopoverMutation {
    public static func performWithoutImplicitAnimation(_ body: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            body()
        }
    }

    public static func setContentSize(_ size: NSSize, on popover: NSPopover) {
        if popover.isShown {
            performWithoutImplicitAnimation {
                popover.contentSize = size
            }
        } else {
            popover.contentSize = size
        }
    }
}
