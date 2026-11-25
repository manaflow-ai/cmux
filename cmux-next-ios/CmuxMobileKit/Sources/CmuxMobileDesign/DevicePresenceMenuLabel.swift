#if os(iOS)
import SwiftUI
import UIKit

/// Presence belongs to the device choice, not to every workspace or the page header.
/// Keep the text for VoiceOver: color alone must not carry the connection state.
public struct DevicePresenceMenuLabel: View {
    let name: String
    let isOnline: Bool

    public init(name: String, isOnline: Bool) {
        self.name = name
        self.isOnline = isOnline
    }

    public var body: some View {
        Label {
            Text(verbatim: name)
        } icon: {
            Image(uiImage: UIImage(systemName: "circle.fill")!
                .withTintColor(isOnline ? .systemGreen : .systemRed, renderingMode: .alwaysOriginal))
        }
        .accessibilityValue(isOnline
            ? String(localized: "mobile.devicePresence.online", defaultValue: "Online", bundle: .module)
            : String(localized: "mobile.devicePresence.offline", defaultValue: "Offline", bundle: .module))
    }
}
#endif
