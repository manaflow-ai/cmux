import SwiftUI

struct SimulatorWebInspectorResponses: View {
    let responses: [SimulatorWebInspectorResponse]
    let clear: () -> Void

    var body: some View {
        HStack {
            Text(simulatorStrings.inspectorResponses)
                .font(.caption.weight(.medium))
            Spacer()
            Button(simulatorStrings.clearInspectorResponses, action: clear)
                .disabled(responses.isEmpty)
        }
        if responses.isEmpty {
            Text(simulatorStrings.noInspectorResponses)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(responses) { response in
                VStack(alignment: .leading, spacing: 2) {
                    if response.isTruncated {
                        Text(simulatorStrings.truncatedInspectorResponse)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(verbatim: response.text)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}
