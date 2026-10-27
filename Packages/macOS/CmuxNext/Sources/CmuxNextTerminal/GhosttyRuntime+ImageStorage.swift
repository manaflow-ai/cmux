public import CmuxNextCompat
import CmuxNextMemory
public import CmuxNextWakeups
import GhosttyNextKit

extension GhosttyRuntime {
    /// The bounded viewer budget per screen the runtime starts with (`SubsystemBudget.boundedKittyImageBytesPerSurface`).
    /// `memorySmallAppStores` sizes it from the Mac's memory instead
    /// (``GhosttyImageStorageBudget/startingBytes(memoryBudget:sizedFromMemory:)``).
    public nonisolated static let defaultImageStorageBytesPerScreen = SubsystemBudget.boundedKittyImageBytesPerSurface

    /// Sets cmux's Kitty graphics budget per screen (`image-storage-limit`) and reloads the config when it
    /// changed. Ghostty keeps a separate budget for the primary and alternate screens, so a surface may retain
    /// about twice this value. An explicit config or theme value takes precedence. A lower budget evicts the
    /// images over it, oldest first, as Ghostty applies the reloaded config.
    ///
    /// - Parameter bytes: Bytes per screen; at least 1, since 0 turns the Kitty graphics protocol off.
    public func setImageStorageBytesPerScreen(_ bytes: Int) {
        let bytes = max(bytes, 1)
        guard bytes != imageStorageBytesPerScreen else { return }
        imageStorageBytesPerScreen = bytes
        // Before the first build starts this does nothing: that build reads the new budget.
        reloadConfig()
    }

    /// The inputs of a config build asked for now, with cmux's Kitty graphics budget.
    func configInputs(theme: String?) -> GhosttyConfigInputs {
        var inputs = GhosttyConfigInputs.current(theme: theme)
        inputs.imageStorageBytes = imageStorageBytesPerScreen
        return inputs
    }

    /// The config line of a budget of `bytes` per screen.
    nonisolated static func imageStorageLine(bytes: Int) -> String {
        "image-storage-limit = \(UInt32(clamping: max(bytes, 1)))"
    }

    /// Loads cmux's budget after finalization only when neither the user's config files nor their theme
    /// assigned the key.
    nonisolated static func loadImageStorageDefaultIfUnset(_ bytes: Int, into config: ghostty_config_t) {
        let key = "image-storage-limit"
        var source = ghostty_config_source_s()
        // SAFETY: the caller passes a live config; Swift passes a NUL-terminated copy of `key`
        // for the call, and Ghostty fills `source`, which lives for the call.
        let explicitlySet = unsafe ghostty_config_key_source(config, key, UInt(key.utf8.count), &source)
        guard !explicitlySet else { return }
        // SAFETY: the caller passes a live config.
        unsafe loadConfigLine(imageStorageLine(bytes: bytes), into: config, source: "cmux-next")
    }
}

/// The app Ghostty's Kitty graphics budget under memory pressure: the full budget per screen
/// (`SubsystemBudget.kittyImageBytesPerSurface`) at normal pressure, half of it at warning and critical, never 0.
///
/// It follows the memory coordinator's level (``MemoryPressureVoteSource``, the debug override included) and is not
/// a memory consumer: libghostty reports no image bytes, so it has none to report, and the budget is a cap that
/// Ghostty enforces, not a store cmux releases. Lowering it costs one config reload that walks every surface and
/// evicts images for good, so the budget falls at once but rises only after the level stayed normal for the
/// coordinator's rise delay (`MemoryCoordinator.limitRiseDelay`): a warning/normal flap makes no reload.
@MainActor
public final class GhosttyImageStorageBudget {
    /// The budget per screen at normal pressure.
    public let fullBytes: Int
    /// The budget per screen it set last.
    public private(set) var bytes: Int
    /// Applies a budget per screen (``GhosttyRuntime/setImageStorageBytesPerScreen(_:)`` in the app).
    private let apply: @MainActor (Int) -> Void
    /// The one-shot that raises the budget once the level stayed normal for ``riseDelay``.
    private let riseDeadline: MainDeadline
    private let riseDelay: Duration
    private var observation: MainActorHandlerRegistration<MemoryPressureLevel>?

    /// - Parameters:
    ///   - fullBytes: The budget per screen at normal pressure.
    ///   - riseDeadline: The one-shot of a budget rise (the app's `MainDeadline`, class background).
    ///   - riseDelay: How long the level stays normal before the budget rises (`MemoryCoordinator.limitRiseDelay`).
    ///   - apply: Applies a budget per screen; tests record it.
    public init(fullBytes: Int, riseDeadline: MainDeadline, riseDelay: Duration, apply: @escaping @MainActor (Int) -> Void) {
        self.fullBytes = max(fullBytes, 1)
        bytes = self.fullBytes
        self.riseDeadline = riseDeadline
        self.riseDelay = riseDelay
        self.apply = apply
    }

    /// The budget per screen the app starts with: `memoryBudget` when `sizedFromMemory` (`memorySmallAppStores`),
    /// else the fixed ``GhosttyRuntime/defaultImageStorageBytesPerScreen``.
    ///
    /// - Parameters:
    ///   - memoryBudget: `SubsystemBudget.kittyImageBytesPerSurface` of this Mac.
    ///   - sizedFromMemory: Whether the feature `memorySmallAppStores` is on.
    /// - Returns: Bytes per screen, at least 1.
    public nonisolated static func startingBytes(memoryBudget: Int, sizedFromMemory: Bool) -> Int {
        sizedFromMemory ? max(memoryBudget, 1) : GhosttyRuntime.defaultImageStorageBytesPerScreen
    }

    /// The budget per screen at `level`: half the full budget below normal pressure, never 0.
    public func budget(at level: MemoryPressureLevel) -> Int {
        level == .normal ? fullBytes : max(fullBytes / 2, 1)
    }

    /// Follows `source`'s level from now on, starting with its current one; a later call replaces the source.
    ///
    /// - Parameter source: The memory coordinator (injected).
    public func follow(_ source: any MemoryPressureVoteSource) {
        observation?.cancel()
        observation = source.observePressureVote { [weak self] level in self?.levelDidChange(level) }
        levelDidChange(source.pressureVote)
    }

    /// Lowers the budget at once (one config reload); a rise waits until the level stayed for ``riseDelay``.
    public func levelDidChange(_ level: MemoryPressureLevel) {
        let next = budget(at: level)
        guard next > bytes else {
            riseDeadline.cancel()
            return setBudget(next)
        }
        riseDeadline.schedule(after: riseDelay) { [weak self] in self?.setBudget(next) }
    }

    private func setBudget(_ next: Int) {
        guard next != bytes else { return }
        bytes = next
        apply(next)
    }
}
