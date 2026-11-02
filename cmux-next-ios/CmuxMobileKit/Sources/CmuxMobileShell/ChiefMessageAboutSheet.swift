#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI

/// Send Message… on a workspace or a tab (the Mac's `home.messageAbout`): a message to the
/// Chief that starts with a link to what it is about, then what the person writes.
struct ChiefMessageAboutSheet: View {
    let subject: ChiefMessageAbout
    let send: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private var message: String {
        (subject.mention + text.trimmingCharacters(in: .whitespacesAndNewlines)).trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(subject.title, systemImage: "link")
                        .lineLimit(2)
                        .accessibilityLabel(Text("About \(subject.title)"))
                        .accessibilityIdentifier("chief.messageAbout.subject")
                } footer: {
                    Text("Chief gets a link to it with your message.")
                }
                Section {
                    TextField("Message", text: $text, axis: .vertical)
                        .lineLimit(3...10)
                        .focused($focused)
                        .accessibilityIdentifier("chief.messageAbout.field")
                }
            }
            .navigationTitle("Message Chief")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", systemImage: "arrow.up") { send(message) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("chief.messageAbout.send")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { focused = true }
    }
}
#endif
