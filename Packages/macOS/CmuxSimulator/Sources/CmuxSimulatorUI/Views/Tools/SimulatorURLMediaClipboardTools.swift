import SwiftUI

struct SimulatorURLMediaClipboardTools: View {
    let coordinator: SimulatorPaneCoordinator
    @State private var url = "https://"
    @State private var clipboard = ""

    var body: some View {
        SimulatorToolSection(simulatorStrings.urlAndMedia) {
            TextField(String(localized: simulatorStrings.url), text: $url)
            HStack {
                Button(simulatorStrings.openURL) { Task { await coordinator.openURL(url) } }
                Button(simulatorStrings.addMedia) { Task { await coordinator.addMedia() } }
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
            Button(simulatorStrings.readClipboard) { Task { await coordinator.readClipboard() } }
            Button(simulatorStrings.writeClipboard) { Task { await coordinator.writeClipboard(clipboard) } }
            Button(simulatorStrings.syncClipboard) { Task { await coordinator.syncClipboardFromHost() } }
        }
    }
}
