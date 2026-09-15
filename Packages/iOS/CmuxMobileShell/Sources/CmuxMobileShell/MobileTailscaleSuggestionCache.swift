import CMUXMobileCore
import CmuxMobileShellModel
import Foundation

/// Device-local hints, bounded to ten minutes and the account/team generation that received them.
@MainActor
final class MobileTailscaleSuggestionCache {
    struct Entry {
        let scope: MobileShellScopeSnapshot
        let groups: [MobileComputerRouteGroup]
        let receivedAt: Date
    }
    private var entries: [MacPairingKey: Entry] = [:]

    func record(_ routes: [CmxAttachRoute], for key: MacPairingKey, scope: MobileShellScopeSnapshot, now: Date) {
        entries = entries.filter { $0.value.scope == scope && now.timeIntervalSince($0.value.receivedAt) < 600 }
        if entries.count >= 100, entries[key] == nil,
           let oldest = entries.min(by: { $0.value.receivedAt < $1.value.receivedAt })?.key {
            entries[oldest] = nil
        }
        entries[key] = Entry(scope: scope, groups: MobileComputerRouteGroup.suggestions(routes), receivedAt: now)
    }

    func groups(for key: MacPairingKey, scope: MobileShellScopeSnapshot, now: Date) -> [MobileComputerRouteGroup] {
        guard let entry = entries[key], entry.scope == scope,
              (0..<600).contains(now.timeIntervalSince(entry.receivedAt)) else { return [] }
        return entry.groups
    }

    func clear() { entries.removeAll() }
}
