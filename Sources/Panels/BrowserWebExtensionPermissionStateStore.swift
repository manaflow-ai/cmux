import Foundation

@available(macOS 15.4, *)
struct BrowserWebExtensionPermissionStateStore {
    private static let storageKey = "browser.webExtensionPermissionStates.v2"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func state(for entryID: String, standardizedPath: String) -> BrowserWebExtensionPermissionState? {
        allStates()[storageIdentity(entryID: entryID, standardizedPath: standardizedPath)]
    }

    func save(_ state: BrowserWebExtensionPermissionState, for entryID: String, standardizedPath: String) {
        var states = allStates()
        states[storageIdentity(entryID: entryID, standardizedPath: standardizedPath)] = state
        saveAllStates(states)
    }

    func removeState(for entryID: String, standardizedPath: String) {
        var states = allStates()
        let identity = storageIdentity(entryID: entryID, standardizedPath: standardizedPath)
        guard states.removeValue(forKey: identity) != nil else { return }
        saveAllStates(states)
    }

    private func storageIdentity(entryID: String, standardizedPath: String) -> String {
        "\(entryID)\n\(standardizedPath)"
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
        guard !states.isEmpty else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        guard let data = try? PropertyListEncoder().encode(states) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
