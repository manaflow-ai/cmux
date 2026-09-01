#if os(iOS)
import SwiftUI

/// The phone-owned computer row shown above paired Macs in the Computers list.
/// It uses a normal disclosure row so the local terminal follows the same
/// navigation affordance as every other computer without pretending to be a
/// remote workspace or connection.
struct MobileLocalComputerRow: View {
    /// Snapshot presentation values at the list boundary. The row must not
    /// retain the mutable app provider as SwiftUI reevaluates its body.
    let title: String
    let subtitle: String
    let symbolName: String
    /// SwiftUI may evaluate this while it constructs the ``NavigationLink``,
    /// before the user selects the row. The closure must only construct and
    /// return a view value; it must not start a session or mutate UI or
    /// controller state.
    let destination: @MainActor () -> AnyView

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.blue.gradient)
                        .frame(width: 40, height: 40)
                    Image(systemName: symbolName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
            }
            .frame(minHeight: 44)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileLocalComputerRow")
    }
}
#endif
