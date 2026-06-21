#if DEBUG
import Foundation
import SwiftUI

struct SyncTypingDemoView: View {
    @State private var draft = ""
    @State private var committed = false
    @FocusState private var inputFocused: Bool

    private var rows: [String] {
        var output = [
            "cmux iOS terminal",
            "host: cloud macOS runner",
            "$ \(draft)",
        ]
        if committed {
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("echo ") {
                output.append(String(trimmed.dropFirst("echo ".count)))
            } else if !trimmed.isEmpty {
                output.append(trimmed)
            }
        }
        return output
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Text(row)
                        .font(.system(size: 17, weight: .regular, design: .monospaced))
                        .foregroundStyle(row.hasPrefix("$") ? Color(red: 0.71, green: 0.94, blue: 0.61) : TerminalPalette.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 76)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("MobileSyncDemoTerminal")
            .accessibilityLabel(rows.joined(separator: "\n"))

            Spacer()

            TextField("", text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($inputFocused)
                .submitLabel(.return)
                .onSubmit { committed = true }
                .accessibilityIdentifier("MobileSyncDemoInput")
                .frame(height: 1)
                .opacity(0.01)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TerminalPalette.background.ignoresSafeArea())
        .onAppear {
            inputFocused = true
        }
        .onChange(of: draft) { _, _ in
            committed = false
        }
    }
}
#endif
