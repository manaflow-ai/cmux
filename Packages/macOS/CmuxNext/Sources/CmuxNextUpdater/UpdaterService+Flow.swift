import Foundation

/// Red-test stubs for the gate wiring.
extension UpdaterService {
    public var card: UpdateCard? { nil }
    public var showsSettingsBadge: Bool { false }
    public func cardClicked() {}
    public func installNow() {}
    public func interruptAnswered(install: Bool) {}
    public func blockersChanged(_ blockers: UpdateBlockers) {}
    public func prepareForQuit() -> UpdateQuitAction { .proceed }
}
