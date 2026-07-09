import Foundation

@available(macOS 15.4, *)
struct BrowserWebExtensionPermissionStateStore {
    private static let storageKey = "browser.webExtensionPermissionStates.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func state(for entryID: String) -> BrowserWebExtensionPermissionState? {
        allStates()[entryID]
    }

    func save(_ state: BrowserWebExtensionPermissionState, for entryID: String) {
        var states = allStates()
        states[entryID] = state
        saveAllStates(states)
    }

    private func allStates() -> [String: BrowserWebExtensionPermissionState] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let states = try? PropertyListDecoder().decode(
                  [String: BrowserWebExtensionPermissionState].self,
                  from: data
              ) else {
            return [:]
        }
        return states
    }

    private func saveAllStates(_ states: [String: BrowserWebExtensionPermissionState]) {
        guard let data = try? PropertyListEncoder().encode(states) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
