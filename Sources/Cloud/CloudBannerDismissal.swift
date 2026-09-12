import Foundation
import SwiftUI

/// Persists dismissal state for Cloud banners without hiding a later state of
/// the same banner. A signature is stored with each id, so changed copy or
/// action state automatically makes the banner visible again.
struct CloudBannerDismissalStore {
    private static let defaultsKey = "cmux.cloud.banner.dismissed"

    private let defaults: UserDefaults
    private var dismissedSignatures: [String: String]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        dismissedSignatures = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    func isDismissed(id: String, signature: String) -> Bool {
        dismissedSignatures[id] == signature
    }

    mutating func dismiss(id: String, signature: String) {
        dismissedSignatures[id] = signature
        persist()
    }

    mutating func clear(id: String) {
        dismissedSignatures.removeValue(forKey: id)
        persist()
    }

    private func persist() {
        defaults.set(dismissedSignatures, forKey: Self.defaultsKey)
    }
}

/// The shared close affordance for persistent Cloud banners.
struct CloudBannerDismissButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(String(localized: "common.close", defaultValue: "Close"))
        .accessibilityLabel(String(localized: "common.close", defaultValue: "Close"))
        .accessibilityIdentifier("CloudBannerDismissButton")
    }
}
