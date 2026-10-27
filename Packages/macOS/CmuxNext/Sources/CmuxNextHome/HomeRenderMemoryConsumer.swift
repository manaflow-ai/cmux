public import CmuxHomeRender
public import CmuxNextCompat

/// The Home render caches the Mac gives to its memory coordinator: one lossless consumer per live
/// `HomeController`, each with an equal share of one byte budget (`SubsystemBudget.homeRenderBitmapBytes`,
/// p07-memory.md task 080).
///
/// Chrome registers each cache as its own consumer where it is built
/// (base/memory_coordinator/memory_consumer.h); the render core is shared with iOS and knows no
/// CmuxNext type, so this adapter registers its engine-neutral surface (`memoryBudget`,
/// `memoryBytes`, `measurementBytes`, `trim(toFraction:)`, `setHidden(_:)`).
///
/// ```swift
/// let consumer = homeRenderMemory.register(controller)  // the host keeps it with the controller
/// consumer.setHidden(true)                              // the tab parked: the caches go to 0
/// ```
@MainActor
public final class HomeRenderMemoryConsumers {
    /// The bytes all members keep together at the full limit.
    public let budgetBytes: Int
    private let registry: any MemoryConsumerRegistry
    private var members: [WeakMember] = []

    private struct WeakMember {
        weak var consumer: HomeRenderMemoryConsumer?
    }

    /// Makes an empty group.
    ///
    /// - Parameters:
    ///   - budgetBytes: The bytes all members keep together at the full limit.
    ///   - registry: The memory coordinator each member registers with.
    public init(budgetBytes: Int, registry: any MemoryConsumerRegistry) {
        self.budgetBytes = max(0, budgetBytes)
        self.registry = registry
    }

    /// The live members.
    public var count: Int {
        members.count(where: { $0.consumer != nil })
    }

    /// Registers `controller` as one consumer and shares the budget again among the live members.
    /// The host keeps the result as long as the controller lives and cancels it when it closes.
    ///
    /// - Parameter controller: The controller whose caches the coordinator limits.
    /// - Returns: The consumer.
    public func register(_ controller: HomeController) -> HomeRenderMemoryConsumer {
        members.removeAll { $0.consumer == nil }
        let consumer = HomeRenderMemoryConsumer(
            controller: controller, group: self, shareBytes: budgetBytes / (members.count + 1), registry: registry)
        members.append(WeakMember(consumer: consumer))
        reshare()
        return consumer
    }

    /// A member left: the others share its part.
    func remove(_ consumer: HomeRenderMemoryConsumer) {
        members.removeAll { $0.consumer == nil || $0.consumer === consumer }
        reshare()
    }

    private func reshare() {
        let share = budgetBytes / max(1, members.count)
        for member in members { member.consumer?.setShare(share) }
    }
}

/// One `HomeController`'s caches as a lossless memory consumer: the limit scales its share of the
/// group's budget, a release trims the oldest bitmaps and pictures down to it, and a hidden
/// transcript keeps no bitmap or picture. The rows on screen keep theirs at any limit (their layers
/// hold them; Chrome's cc keeps the tiles of the visible rect the same way), and the text
/// measurements are reported but never released: every commit reads them.
@MainActor
public final class HomeRenderMemoryConsumer {
    /// Large (a screen of row bitmaps and the screens around it), dropped by unlinking, and drawn
    /// again off the main actor on the next miss: it shrinks at warning and empties at critical.
    public static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .large,
        dataAccess: .none,
        retention: .lossless,
        recreateCost: .cheap,
        releaseCPUCost: .low,
        isStateful: true,
        supportsMemoryLimit: true
    )

    /// The consumer's name in the memory report (one row per live controller).
    public static let memoryConsumerName = "home-render"

    private weak var controller: HomeController?
    private weak var group: HomeRenderMemoryConsumers?
    /// The controller's part of the group's budget at the full limit.
    public private(set) var shareBytes: Int
    /// The limit the coordinator gave last.
    public private(set) var limit = MemoryLimit.default
    /// The host hid the transcript: its caches keep nothing.
    public private(set) var isHidden = false
    private var registration: MemoryConsumerRegistration?

    fileprivate init(controller: HomeController, group: HomeRenderMemoryConsumers, shareBytes: Int,
                     registry: any MemoryConsumerRegistry) {
        self.controller = controller
        self.group = group
        self.shareBytes = shareBytes
        registration = MemoryConsumerRegistration(
            name: Self.memoryConsumerName, traits: Self.memoryTraits, consumer: self, registry: registry)
    }

    /// The bytes the controller's caches may keep now: its share scaled by the limit, 0 while hidden.
    public var allowedBytes: Int {
        isHidden ? 0 : limit.scale(shareBytes)
    }

    /// The host hid (a parked tab, an unselected conversation) or showed the transcript. Hiding drops
    /// every bitmap and picture at once, the rows' included, and stops drawing until it shows; showing
    /// gives the budget back and lays out once, and the rows on screen draw again.
    ///
    /// - Parameter hidden: Whether the transcript is hidden.
    public func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        isHidden = hidden
        applyBudget()
        controller?.setHidden(hidden)
    }

    /// The controller closed: the coordinator stops calling, and the other members share its part.
    public func cancel() {
        registration?.cancel()
        registration = nil
        group?.remove(self)
    }

    fileprivate func setShare(_ bytes: Int) {
        guard bytes != shareBytes else { return }
        shareBytes = bytes
        applyBudget()
    }

    /// Lowers or raises the caches' caps; frees nothing.
    private func applyBudget() {
        controller?.memoryBudget = HomeMemoryBudget(bytes: allowedBytes)
    }
}

extension HomeRenderMemoryConsumer: MemoryConsumer {
    /// Scales the caches' caps from now on; frees nothing (the next store drops the oldest).
    public func updateMemoryLimit(_ limit: MemoryLimit) {
        self.limit = limit
        applyBudget()
    }

    /// Trims the oldest bitmaps and pictures down to what the slice's limit allows, in one pass of
    /// dictionary unlinks. Only the budgeted caches are compared with the limit: what the rows on
    /// screen show stays (releasing it frees nothing their layers hold) and measurements stay.
    public func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        updateMemoryLimit(slice.limit)
        guard let controller else { return .done }
        let held = controller.memoryBytes
        let cap = allowedBytes
        if held > cap { controller.trim(toFraction: Double(cap) / Double(held)) }
        return .done
    }

    /// What the controller holds now: bitmaps, pictures and text measurements; nothing once the
    /// controller is gone.
    public var memoryUsage: MemoryUsage? {
        guard let controller else { return .empty }
        return MemoryUsage(footprintBytes: controller.memoryBytes + controller.measurementBytes,
                           entries: controller.memoryEntryCount + controller.measurementCount)
    }
}
