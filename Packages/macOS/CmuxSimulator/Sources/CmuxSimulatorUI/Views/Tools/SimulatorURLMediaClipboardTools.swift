import SwiftUI

struct SimulatorURLMediaClipboardTools: View {
    let coordinator: SimulatorPaneCoordinator
    @State private var url = "https://"
    @State private var clipboard = ""

    var body: some View {
        SimulatorToolSection(simulatorStrings.urlAndMedia) {
            TextField(String(localized: simulatorStrings.url), text: $url)
            HStack {
                SimulatorLocalizedButton(simulatorStrings.openURL) {
                    coordinator.scheduleControlAction("open-url") { await $0.openURL(url) }
                }
                SimulatorLocalizedButton(simulatorStrings.addMedia) {
                    coordinator.scheduleControlAction("add-media") { await $0.addMedia() }
                }
            }
            Divider()
            Text(simulatorStrings.clipboard).font(.subheadline.weight(.semibold))
            TextEditor(text: $clipboard)
                .font(.caption.monospaced())
                .frame(minHeight: 52)
                .overlay { RoundedRectangle(cornerRadius: 4).stroke(.separator) }
            ViewThatFits {
                HStack { clipboardButtons }
                VStack(alignment: .leading) { clipboardButtons }
            }
        }
        .onChange(of: coordinator.clipboardText) { _, text in clipboard = text }
    }

    private var clipboardButtons: some View {
        Group {
            SimulatorLocalizedButton(simulatorStrings.readClipboard) {
                coordinator.scheduleControlAction("read-clipboard") { await $0.readClipboard() }
            }
            SimulatorLocalizedButton(simulatorStrings.writeClipboard) {
                coordinator.scheduleControlAction("write-clipboard") { await $0.writeClipboard(clipboard) }
            }
            SimulatorLocalizedButton(simulatorStrings.syncClipboard) {
                coordinator.scheduleControlAction("sync-clipboard") { await $0.syncClipboardFromHost() }
            }
        }
    }
}
