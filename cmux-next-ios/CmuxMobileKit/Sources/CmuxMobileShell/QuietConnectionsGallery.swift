#if DEBUG && os(iOS)
import CmuxMobileDesign
import SwiftUI

/// `quiet-a|b|c`: contextual dots (selected), contextual symbols, or explicit status.
/// The production chip uses isolated defaults so gallery launches never change a person's setting.
struct QuietConnectionsGallery: View {
    let variant: String
    @State private var selection = "Studio"

    private var defaults: UserDefaults? {
        let value = UserDefaults(suiteName: "cmux.gallery.quietConnections")
        value?.set(true, forKey: CmuxMobilePreferences.Key.quietConnections)
        return value
    }

    var body: some View {
        if let defaults {
            NavigationStack {
                List {
                    Section {
                        ForEach(["Studio", "Build server", "Laptop"], id: \.self) { name in
                            Button { selection = name } label: {
                                HStack {
                                    device(name, online: name != "Laptop")
                                    Spacer()
                                    if selection == name { Image(systemName: "checkmark") }
                                }
                            }
                            .tint(.primary)
                        }
                    } header: { Text(verbatim: "Devices · variant \(variant.uppercased())") }
                    Section {
                        ForEach(["Release build", "Connection tests", "Notes"], id: \.self) { title in
                            Label { Text(verbatim: title) } icon: { Image(systemName: "terminal") }
                        }
                    } header: { Text(verbatim: selection) }
                    Section {
                        ConnectionChip(.init(.cantReach, sentence: "Retry remains available"), downSince: nil, retry: {})
                    } header: { Text(verbatim: "Actionable failure") }
                }
                .navigationTitle(Text(verbatim: "Workspaces"))
                .overlay(alignment: .top) {
                    ConnectionChip(.init(.reconnecting, sentence: "Reconnecting"), downSince: nil)
                }
            }
            .defaultAppStorage(defaults)
        }
    }

    @ViewBuilder private func device(_ name: String, online: Bool) -> some View {
        switch variant {
        case "b":
            Label { Text(verbatim: name) } icon: {
                Image(systemName: online ? "wifi" : "wifi.slash")
                    .foregroundStyle(online ? Color.green : Color.red)
            }
        case "c":
            VStack(alignment: .leading) {
                Text(verbatim: name)
                Text(verbatim: online ? "Online" : "Offline").font(.caption).foregroundStyle(.secondary)
            }
        default:
            DevicePresenceMenuLabel(name: name, isOnline: online)
        }
    }
}
#endif
