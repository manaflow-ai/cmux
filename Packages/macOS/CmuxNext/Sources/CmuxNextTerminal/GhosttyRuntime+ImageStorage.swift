public import CmuxNextCompat
import GhosttyNextKit

extension GhosttyRuntime {
    /// Sets cmux's Kitty graphics budget per screen (`image-storage-limit`), the app's
    /// `SubsystemBudget.kittyImageBytesPerSurface`, and reloads the config when it changed. Ghostty keeps a
    /// separate budget for the primary and alternate screens, so a surface may retain about twice this value.
    /// An explicit config or theme value takes precedence. A lower budget evicts the images over it, oldest
    /// first, as Ghostty applies the reloaded config.
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
    /// assigned the key. Nil `bytes` (no budget set: tests) keeps Ghostty's own default.
    nonisolated static func loadImageStorageDefaultIfUnset(_ bytes: Int?, into config: ghostty_config_t) {
        guard let bytes else { return }
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

/// The app Ghostty's Kitty graphics budget as a memory consumer: the full budget per screen
/// (`SubsystemBudget.kittyImageBytesPerSurface`) at normal pressure, half of it at warning and critical, never 0.
///
/// Lossy: Ghostty evicts the images over a lowered budget when it applies the reloaded config, and a program's
/// images cannot be drawn again. It follows the pressure level (``MemoryLevelConsumer``), the debug override
/// included, rather than a limit: Chrome has no such cap, and a level change costs one off-main config build.
@MainActor
public final class GhosttyImageStorageConsumer {
    /// The budget per screen at normal pressure.
    public let fullBytes: Int
    /// The budget per screen it set last.
    public private(set) var bytes: Int
    /// Applies a budget per screen (``GhosttyRuntime/setImageStorageBytesPerScreen(_:)`` in the app).
    private let apply: @MainActor (Int) -> Void
    private var registration: MemoryConsumerRegistration?

    /// - Parameters:
    ///   - fullBytes: The budget per screen at normal pressure.
    ///   - apply: Applies a budget per screen; tests record it.
    public init(fullBytes: Int, apply: @escaping @MainActor (Int) -> Void) {
        self.fullBytes = max(fullBytes, 1)
        bytes = self.fullBytes
        self.apply = apply
    }

    /// A consumer of `registry` that applies its budget to `runtime` (``GhosttyRuntime/setImageStorageBytesPerScreen(_:)``);
    /// the caller keeps it.
    ///
    /// - Parameters:
    ///   - fullBytes: The budget per screen at normal pressure.
    ///   - runtime: The app's Ghostty runtime.
    ///   - registry: The memory coordinator (injected).
    /// - Returns: The registered consumer.
    public static func registered(fullBytes: Int, runtime: GhosttyRuntime,
                                  with registry: any MemoryConsumerRegistry) -> GhosttyImageStorageConsumer {
        let consumer = GhosttyImageStorageConsumer(fullBytes: fullBytes) { [weak runtime] in runtime?.setImageStorageBytesPerScreen($0) }
        consumer.registerMemoryConsumer(with: registry)
        return consumer
    }

    /// The budget per screen at `level`: half the full budget below normal pressure, never 0.
    public func budget(at level: MemoryPressureLevel) -> Int {
        level == .normal ? fullBytes : max(fullBytes / 2, 1)
    }

    /// Registers with the app's memory coordinator, which hands it the current level at once; a later call
    /// replaces the registration.
    ///
    /// - Parameter registry: The memory coordinator (injected).
    public func registerMemoryConsumer(with registry: any MemoryConsumerRegistry) {
        registration?.cancel()
        registration = MemoryConsumerRegistration(
            name: Self.memoryConsumerName, traits: Self.memoryTraits, consumer: self, registry: registry)
    }
}

extension GhosttyImageStorageConsumer: MemoryLevelConsumer {
    /// Up to the budget per screen, twice per surface, in Ghostty's terminal state (over 50 MB with many
    /// terminals); lowering it evicts images, which are gone, and walks every surface at the config apply.
    public nonisolated static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .large, dataAccess: .none, retention: .lossy, recreateCost: .notApplicable,
        releaseCPUCost: .high, isStateful: true, supportsMemoryLimit: false)

    /// The consumer's name in the memory report.
    public nonisolated static let memoryConsumerName = "terminal-kitty-images"

    /// Sets the level's budget when it changed (one config reload).
    public func memoryLevelDidChange(_ level: MemoryPressureLevel) {
        let next = budget(at: level)
        guard next != bytes else { return }
        bytes = next
        apply(next)
    }

    /// The level sets the budget (``memoryLevelDidChange(_:)``).
    public func updateMemoryLimit(_ limit: MemoryLimit) {}

    /// The config apply frees the images (``memoryLevelDidChange(_:)``).
    public func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        .done
    }

    /// Unknown: libghostty reports no image bytes.
    public var memoryUsage: MemoryUsage? {
        nil
    }
}
