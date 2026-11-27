import CmuxConversationCore
import Foundation
import Observation

/// Chief: Zoom In, Zoom Out and Actual Size (the Mac's `home.zoomIn`,
/// `home.zoomOut`, `home.zoomReset`, which step one Chief zoom for every Chief
/// conversation). On the phone the step counts Dynamic Type sizes from the
/// person's own size, so the Chief transcript zooms the way the system text
/// size does; it is saved on this phone, one setting for every Chief.
@MainActor
@Observable
public final class ChiefTextZoom {
    public static let shared = ChiefTextZoom()
    static let defaultsKey = "cmux.chief.textZoom.v1"

    /// Sizes from the person's own (0: Actual Size).
    public private(set) var step: Int
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        step = defaults.integer(forKey: Self.defaultsKey)
    }

    /// The size Chief draws at over the person's `system` size; nil (the
    /// system's own) at Actual Size.
    public func textSize(system: ConversationTextSize) -> ConversationTextSize? {
        step == 0 ? nil : system.stepped(by: step)
    }

    /// The size shown now, as a share of Actual Size, in percent.
    public func percent(system: ConversationTextSize) -> Int {
        system.stepped(by: step).percent(of: system)
    }

    public func canZoomIn(system: ConversationTextSize) -> Bool {
        let shown = clamped(step, system: system)
        return system.stepped(by: shown) < system.stepped(by: shown + 1)
    }

    public func canZoomOut(system: ConversationTextSize) -> Bool {
        let shown = clamped(step, system: system)
        return system.stepped(by: shown - 1) < system.stepped(by: shown)
    }

    public func zoomIn(system: ConversationTextSize) {
        guard canZoomIn(system: system) else { return }
        save(step: clamped(step, system: system) + 1)
    }

    public func zoomOut(system: ConversationTextSize) {
        guard canZoomOut(system: system) else { return }
        save(step: clamped(step, system: system) - 1)
    }

    public func actualSize() {
        save(step: 0)
    }

    /// The step as drawn over `system`: one saved at another system size that
    /// reaches past the smallest or largest counts from where it stops, so
    /// one tap always moves the text.
    private func clamped(_ wanted: Int, system: ConversationTextSize) -> Int {
        let all = ConversationTextSize.allCases
        let base = all.firstIndex(of: system) ?? 0
        let target = all.firstIndex(of: system.stepped(by: wanted)) ?? base
        return target - base
    }

    private func save(step: Int) {
        guard step != self.step else { return }
        self.step = step
        if step == 0 { defaults.removeObject(forKey: Self.defaultsKey) } else { defaults.set(step, forKey: Self.defaultsKey) }
    }
}
