import AppKit
import SwiftUI

struct ApplicationSurfacePickerRow: View {
    let window: ApplicationWindowDescriptor

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = NSRunningApplication(
                    processIdentifier: pid_t(window.processID)
                )?.icon {
                    Image(nsImage: icon)
                        .resizable()
                } else {
                    Image(systemName: "app")
                        .resizable()
                        .padding(5)
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(contentMode: .fit)
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(window.title)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(window.owner)
                    Text(verbatim: "•")
                    Text(verbatim: "\(Int(window.width)) × \(Int(window.height))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
