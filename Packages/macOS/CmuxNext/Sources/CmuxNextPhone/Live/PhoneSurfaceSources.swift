public import Foundation

/// hostd's `surface` sources by tab: `d~<display>` to this Mac's displays (``MacDisplaySurfaceSources``),
/// every other tab to the phone tabs' simulators (``SimulatorSurfaceSources``; nil when SimulatorKit does not load).
@MainActor
public final class PhoneSurfaceSources {
    private let phoneTabs: SimulatorSurfaceSources?
    private let macDisplays: MacDisplaySurfaceSources

    public init(phoneTabs: SimulatorSurfaceSources?, macDisplays: MacDisplaySurfaceSources) {
        self.phoneTabs = phoneTabs
        self.macDisplays = macDisplays
    }

    public func start(tab: String, onExit: @escaping @Sendable () -> Void) async throws -> (port: UInt16, secret: String) {
        if MacDisplaySurfaceSources.display(of: tab) != nil { return try await macDisplays.start(tab: tab, onExit: onExit) }
        guard let phoneTabs else { throw SimulatorSurfaceSources.Failure.notPhoneTab }
        return try await phoneTabs.start(tab: tab, onExit: onExit)
    }

    public func stop(tab: String) {
        if MacDisplaySurfaceSources.display(of: tab) != nil { return macDisplays.stop(tab: tab) }
        phoneTabs?.stop(tab: tab)
    }

    public func stopAll() {
        macDisplays.stopAll()
        phoneTabs?.stopAll()
    }
}
