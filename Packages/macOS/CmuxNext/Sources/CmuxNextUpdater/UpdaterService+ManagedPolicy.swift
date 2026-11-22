import CmuxUpdater
public import Foundation

/// The device keys `UpdateChannel` and `MinimumVersion` (spec/enterprise.md
/// 5.2, plans/cmux-next/enterprise.md P17-2). The App sets them from the
/// managed policy (`SettingsController.managedPolicy`, the one reader).
extension UpdaterService {
    /// The running version is older than `MinimumVersion`: the minimum, else nil.
    public var requiredMinimumVersion: String? {
        guard let minimum = managedMinimumVersion,
              Self.isOlder(identity.shortVersion, than: minimum) else { return nil }
        return minimum
    }

    /// Why switching to `target` is refused by `UpdateChannel`, or nil.
    func managedChannelRefusal(_ target: AppChannelSwitchTarget) -> UpdaterUnavailable? {
        guard let channel = managedChannel, channel != target else { return nil }
        return UpdaterUnavailable.managedChannel(UpdaterStrings.channel(channel == .nightly ? .nightly : .stable))
    }

    /// Applies new managed values. An update the organization requires is
    /// checked for when it becomes required (not on every settings reload)
    /// and again by ``recheckRequiredUpdate()``; the sheet offers no "Later".
    /// An unknown channel name pins nothing.
    public func applyManagedPolicy(channel: String?, minimumVersion: String?) {
        let wasRequired = requiredMinimumVersion
        managedChannel = channel.flatMap { AppChannelSwitchTarget(rawValue: $0.lowercased()) }
        managedMinimumVersion = minimumVersion?.trimmingCharacters(in: .whitespaces)
        if requiredMinimumVersion != wasRequired { recheckRequiredUpdate() }
    }

    /// Shows the required update again (app activation, Sparkle start) while
    /// one is required and Sparkle is idle; a dismissed sheet comes back.
    public func recheckRequiredUpdate() {
        guard requiredMinimumVersion != nil, isStarted, let controller, disabledReason == nil else { return }
        guard case .idle = controller.model.effectiveState else { return }
        checkForUpdates()
    }

    /// True when `version` is older than `minimum` (major.minor.patch; a
    /// missing part is 0, so "0.65" means 0.65.0; a pre-release counts as its
    /// release; unreadable versions are not older).
    nonisolated static func isOlder(_ version: String, than minimum: String) -> Bool {
        func parts(_ text: String) -> [Int]? {
            let core = text.trimmingCharacters(in: .whitespaces).split(separator: "-").first.map(String.init) ?? ""
            let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard (1...3).contains(numbers.count), numbers.allSatisfy({ $0 != nil }) else { return nil }
            return numbers.compactMap { $0 } + Array(repeating: 0, count: 3 - numbers.count)
        }
        guard let have = parts(version), let need = parts(minimum) else { return false }
        return have.lexicographicallyPrecedes(need)
    }
}
